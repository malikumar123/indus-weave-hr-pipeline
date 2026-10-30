USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #months;
    DROP TABLE IF EXISTS #employee_months;

    -- 1. Six reporting months.
    CREATE TABLE #months (
        month_start DATE NOT NULL PRIMARY KEY
    );

    INSERT INTO #months (month_start)
    VALUES
        ('20260401'),
        ('20260501'),
        ('20260601'),
        ('20260701'),
        ('20260801'),
        ('20260901');


    -- 2. Choose the department attribution date.
    WITH attribution_dates AS (
        SELECT
            e.emp_id,
            m.month_start,

            CASE
                WHEN e.separation_date <= EOMONTH(m.month_start)
                THEN e.separation_date
                ELSE EOMONTH(m.month_start)
            END AS attribution_date,

            CAST(
                CASE
                    WHEN e.separation_date IS NULL
                      OR e.separation_date > EOMONTH(m.month_start)
                    THEN 1 ELSE 0
                END AS BIT
            ) AS is_month_end_headcount,

            CAST(
                CASE
                    WHEN e.separation_date IS NULL
                      OR e.separation_date >= m.month_start
                    THEN 1 ELSE 0
                END AS BIT
            ) AS employed_during_month

        FROM staging.employees AS e
        CROSS JOIN #months AS m

        -- Keep later months for separated employees, allowing
        -- post-separation payroll to remain visible.
        WHERE e.hire_date <= EOMONTH(m.month_start)
    )
    SELECT
        a.emp_id,
        a.month_start,
        a.attribution_date,
        h.dept_id,
        h.effective_from AS history_effective_from,
        a.is_month_end_headcount,
        a.employed_during_month

    INTO #employee_months

    FROM attribution_dates AS a
    LEFT JOIN staging.employment_history AS h
        ON a.emp_id = h.emp_id
       AND a.attribution_date >= h.effective_from
       AND (
           h.effective_to IS NULL
           OR a.attribution_date <= h.effective_to
       );


    -- 3. Validate history coverage and uniqueness.
    IF EXISTS (
        SELECT 1
        FROM #employee_months
        WHERE dept_id IS NULL
           OR history_effective_from IS NULL
    )
    BEGIN
        SELECT *
        FROM #employee_months
        WHERE dept_id IS NULL
           OR history_effective_from IS NULL;

        THROW 50160, 'Missing history for employee-month attribution.', 1;
    END;

    IF EXISTS (
        SELECT emp_id, month_start
        FROM #employee_months
        GROUP BY emp_id, month_start
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50161, 'Multiple departments assigned to one employee-month.', 1;


    -- 4. Make sure source activity has an employee-month mapping.
    -- Pre-hire activity would fail this check and require review.
    IF EXISTS (
        SELECT 1
        FROM (
            SELECT emp_id, payroll_month AS month_start
            FROM staging.payroll_lines

            UNION

            SELECT
                emp_id,
                DATEFROMPARTS(YEAR(work_date), MONTH(work_date), 1)
            FROM staging.attendance_daily

            UNION

            SELECT
                emp_id,
                DATEFROMPARTS(YEAR(ot_date), MONTH(ot_date), 1)
            FROM staging.overtime_requests
        ) AS activity

        INNER JOIN #months AS m
            ON activity.month_start = m.month_start

        WHERE NOT EXISTS (
            SELECT 1
            FROM #employee_months AS em
            WHERE em.emp_id = activity.emp_id
              AND em.month_start = activity.month_start
        )
    )
        THROW 50162, 'Source activity lacks employee-month attribution.', 1;


    -- 5. Create and populate the mapping table.
    IF OBJECT_ID(N'staging.employee_month_department', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.employee_month_department (
            emp_id NVARCHAR(50) NOT NULL,
            month_start DATE NOT NULL,
            attribution_date DATE NOT NULL,
            dept_id NVARCHAR(50) NOT NULL,
            history_effective_from DATE NOT NULL,
            is_month_end_headcount BIT NOT NULL,
            employed_during_month BIT NOT NULL,

            PRIMARY KEY (emp_id, month_start),

            CHECK (DAY(month_start) = 1)
        );

        CREATE INDEX IX_employee_month_department
            ON staging.employee_month_department (
                month_start, dept_id
            );
    END;

    DELETE FROM staging.employee_month_department;

    INSERT INTO staging.employee_month_department (
        emp_id,
        month_start,
        attribution_date,
        dept_id,
        history_effective_from,
        is_month_end_headcount,
        employed_during_month
    )
    SELECT
        emp_id,
        month_start,
        attribution_date,
        dept_id,
        history_effective_from,
        is_month_end_headcount,
        employed_during_month
    FROM #employee_months;


    -- 6. Independently verify expected employee-month coverage.
    DECLARE @expected_count BIGINT;

    SELECT @expected_count = COUNT_BIG(*)
    FROM staging.employees AS e
    CROSS JOIN #months AS m
    WHERE e.hire_date <= EOMONTH(m.month_start);

    DECLARE @actual_count BIGINT =
        (SELECT COUNT_BIG(*)
         FROM staging.employee_month_department);

    IF @expected_count <> @actual_count
        THROW 50163, 'Employee-month coverage failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @expected_count AS expected_employee_months,
        @actual_count AS mapped_employee_months,
        'PASS' AS reconciliation;

    SELECT
        month_start,
        COUNT_BIG(*) AS mapped_employees,

        SUM(CAST(
            is_month_end_headcount AS BIGINT
        )) AS month_end_headcount,

        SUM(CAST(
            employed_during_month AS BIGINT
        )) AS employees_employed_during_month

    FROM staging.employee_month_department
    GROUP BY month_start
    ORDER BY month_start;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;