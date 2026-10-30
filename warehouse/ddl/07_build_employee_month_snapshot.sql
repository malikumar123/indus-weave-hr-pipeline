USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #monthly_snapshot;

    IF NOT EXISTS (
        SELECT 1
        FROM staging.employee_month_department
    )
        THROW 50240, 'Employee-month staging input is empty.', 1;


    -- 1. Resolve employee and department versions at attribution date.
    SELECT
        source.emp_id,
        calendar.date_key AS month_date_key,
        employee.employee_key,
        department.department_key,
        employee.department_key AS employee_department_key,
        source.attribution_date,
        source.is_month_end_headcount,
        source.employed_during_month

    INTO #monthly_snapshot

    FROM staging.employee_month_department AS source

    LEFT JOIN warehouse.dim_employee AS employee
        ON source.emp_id = employee.emp_id
       AND source.attribution_date >= employee.valid_from
       AND (
           employee.valid_to IS NULL
           OR source.attribution_date <= employee.valid_to
       )

    LEFT JOIN warehouse.dim_department AS department
        ON source.dept_id = department.dept_id

    LEFT JOIN warehouse.dim_date AS calendar
        ON source.month_start = calendar.calendar_date;


    -- 2. Validate dimension coverage and employee-month grain.
    IF EXISTS (
        SELECT 1
        FROM #monthly_snapshot
        WHERE month_date_key IS NULL
           OR employee_key IS NULL
           OR department_key IS NULL
    )
        THROW 50241, 'Monthly snapshot dimension lookup failed.', 1;

    IF EXISTS (
        SELECT emp_id, month_date_key
        FROM #monthly_snapshot
        GROUP BY emp_id, month_date_key
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50242, 'Duplicate employee-month snapshot rows.', 1;

    IF EXISTS (
        SELECT 1
        FROM #monthly_snapshot
        WHERE department_key <> employee_department_key
    )
        THROW 50243, 'Monthly department disagrees with employee history.', 1;


    -- 3. Create the supporting snapshot fact.
    IF OBJECT_ID(
        N'warehouse.fact_employee_month_snapshot', N'U'
    ) IS NULL
    BEGIN
        CREATE TABLE warehouse.fact_employee_month_snapshot (
            emp_id NVARCHAR(50) NOT NULL,
            month_date_key INT NOT NULL,
            employee_key INT NOT NULL,
            department_key INT NOT NULL,
            attribution_date DATE NOT NULL,
            is_month_end_headcount BIT NOT NULL,
            employed_during_month BIT NOT NULL,

            PRIMARY KEY (emp_id, month_date_key),

            FOREIGN KEY (month_date_key)
                REFERENCES warehouse.dim_date(date_key),

            FOREIGN KEY (employee_key)
                REFERENCES warehouse.dim_employee(employee_key),

            FOREIGN KEY (department_key)
                REFERENCES warehouse.dim_department(department_key)
        );

        CREATE INDEX IX_snapshot_month_department
            ON warehouse.fact_employee_month_snapshot (
                month_date_key, department_key
            );
    END;


    -- 4. Rebuild the snapshot.
    DELETE FROM warehouse.fact_employee_month_snapshot;

    INSERT INTO warehouse.fact_employee_month_snapshot (
        emp_id,
        month_date_key,
        employee_key,
        department_key,
        attribution_date,
        is_month_end_headcount,
        employed_during_month
    )
    SELECT
        emp_id,
        month_date_key,
        employee_key,
        department_key,
        attribution_date,
        is_month_end_headcount,
        employed_during_month
    FROM #monthly_snapshot;


    -- 5. Reconcile rows and all prepared snapshot values.
    DECLARE @staging_count BIGINT = (
        SELECT COUNT_BIG(*)
        FROM staging.employee_month_department
    );

    DECLARE @warehouse_count BIGINT = (
        SELECT COUNT_BIG(*)
        FROM warehouse.fact_employee_month_snapshot
    );

    IF @staging_count <> @warehouse_count
        THROW 50244, 'Monthly snapshot row reconciliation failed.', 1;

    IF EXISTS (
        SELECT
            emp_id,
            month_date_key,
            employee_key,
            department_key,
            attribution_date,
            is_month_end_headcount,
            employed_during_month
        FROM #monthly_snapshot

        EXCEPT

        SELECT
            emp_id,
            month_date_key,
            employee_key,
            department_key,
            attribution_date,
            is_month_end_headcount,
            employed_during_month
        FROM warehouse.fact_employee_month_snapshot
    )
        THROW 50245, 'Monthly snapshot values do not match input.', 1;

    COMMIT TRANSACTION;

    SELECT
        @staging_count AS staging_employee_months,
        @warehouse_count AS warehouse_employee_months,
        'PASS' AS reconciliation;

    SELECT
        calendar.month_start,
        COUNT_BIG(*) AS mapped_employees,

        SUM(CAST(
            snapshot.is_month_end_headcount AS BIGINT
        )) AS month_end_headcount,

        SUM(CAST(
            snapshot.employed_during_month AS BIGINT
        )) AS employees_employed_during_month

    FROM warehouse.fact_employee_month_snapshot AS snapshot
    INNER JOIN warehouse.dim_date AS calendar
        ON snapshot.month_date_key = calendar.date_key

    GROUP BY calendar.month_start
    ORDER BY calendar.month_start;

    DROP TABLE IF EXISTS #monthly_snapshot;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;