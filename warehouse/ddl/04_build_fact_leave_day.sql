USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #leave_fact;

    -- Validate upstream classification before rebuilding the fact.
    IF EXISTS (
        SELECT 1
        FROM staging.leave_requests AS r
        LEFT JOIN staging.leave_request_status AS s
            ON r.request_id = s.request_id
        WHERE s.request_id IS NULL
    )
        THROW 50210, 'Leave classifications are incomplete.', 1;

    IF EXISTS (
        SELECT 1
        FROM staging.leave_days AS l
        LEFT JOIN staging.leave_request_status AS s
            ON l.request_id = s.request_id
        WHERE s.request_id IS NULL
           OR s.is_approved <> 1
    )
        THROW 50211, 'A leave day belongs to an unapproved request.', 1;


    -- 1. Resolve the employee version valid on each leave date.
    SELECT
        l.request_id,
        l.emp_id,
        l.leave_date,
        l.leave_type,

        employee.employee_key,
        employee.department_key AS employee_department_key,
        department.department_key,
        calendar.date_key

    INTO #leave_fact

    FROM staging.leave_days AS l

    LEFT JOIN warehouse.dim_employee AS employee
        ON l.emp_id = employee.emp_id
       AND l.leave_date >= employee.valid_from
       AND (
           employee.valid_to IS NULL
           OR l.leave_date <= employee.valid_to
       )

    LEFT JOIN warehouse.dim_department AS department
        ON l.dept_id = department.dept_id

    LEFT JOIN warehouse.dim_date AS calendar
        ON l.leave_date = calendar.calendar_date;


    -- 2. Validate keys, grain, and department consistency.
    IF EXISTS (
        SELECT 1
        FROM #leave_fact
        WHERE employee_key IS NULL
           OR department_key IS NULL
           OR date_key IS NULL
    )
        THROW 50212, 'Leave fact dimension lookup failed.', 1;

    IF EXISTS (
        SELECT request_id, leave_date
        FROM #leave_fact
        GROUP BY request_id, leave_date
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50213, 'Multiple matches for a request/leave date.', 1;

    IF EXISTS (
        SELECT 1
        FROM #leave_fact
        WHERE department_key <> employee_department_key
    )
        THROW 50214, 'Leave department disagrees with employee history.', 1;

    -- Accepted values observed in this dataset.
    IF EXISTS (
        SELECT 1
        FROM #leave_fact
        WHERE leave_type NOT IN ('Annual', 'Casual', 'Sick')
    )
        THROW 50215, 'Unexpected leave type requires review.', 1;


    -- 3. Create the fact with enforced relationships.
    IF OBJECT_ID(N'warehouse.fact_leave_day', N'U') IS NULL
    BEGIN
        CREATE TABLE warehouse.fact_leave_day (
            request_id NVARCHAR(100) NOT NULL,
            date_key INT NOT NULL,
            employee_key INT NOT NULL,
            department_key INT NOT NULL,
            leave_type NVARCHAR(50) NOT NULL,
            leave_day_count TINYINT NOT NULL,

            PRIMARY KEY (request_id, date_key),

            FOREIGN KEY (date_key)
                REFERENCES warehouse.dim_date(date_key),

            FOREIGN KEY (employee_key)
                REFERENCES warehouse.dim_employee(employee_key),

            FOREIGN KEY (department_key)
                REFERENCES warehouse.dim_department(department_key),

            CHECK (leave_type IN ('Annual', 'Casual', 'Sick')),
            CHECK (leave_day_count = 1)
        );

        CREATE INDEX IX_leave_employee_date
            ON warehouse.fact_leave_day (employee_key, date_key);
    END;


    -- 4. Rebuild the fact.
    DELETE FROM warehouse.fact_leave_day;

    INSERT INTO warehouse.fact_leave_day (
        request_id,
        date_key,
        employee_key,
        department_key,
        leave_type,
        leave_day_count
    )
    SELECT
        request_id,
        date_key,
        employee_key,
        department_key,
        leave_type,
        1
    FROM #leave_fact;


    -- 5. Reconcile counts and individual request/date coverage.
    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.leave_days);

    DECLARE @warehouse_count BIGINT =
        (SELECT COUNT_BIG(*) FROM warehouse.fact_leave_day);

    IF @staging_count <> @warehouse_count
        THROW 50216, 'Leave fact row reconciliation failed.', 1;

    IF EXISTS (
        SELECT 1
        FROM #leave_fact AS source
        LEFT JOIN warehouse.fact_leave_day AS target
            ON source.request_id = target.request_id
           AND source.date_key = target.date_key
        WHERE target.request_id IS NULL
    )
        THROW 50217, 'A staged leave day is missing from the warehouse.', 1;

    COMMIT TRANSACTION;

    SELECT
        @staging_count AS staging_leave_days,
        @warehouse_count AS warehouse_leave_days,
        'PASS' AS reconciliation;

    SELECT
        leave_type,
        COUNT_BIG(*) AS leave_days
    FROM warehouse.fact_leave_day
    GROUP BY leave_type
    ORDER BY leave_type;

    DROP TABLE IF EXISTS #leave_fact;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;