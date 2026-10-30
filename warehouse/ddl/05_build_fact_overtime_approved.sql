USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #approved_ot_fact;

    IF NOT EXISTS (SELECT 1 FROM staging.overtime_requests)
        THROW 50220, 'Overtime staging input is empty.', 1;


    -- 1. Resolve dimensions using the request's shift date.
    SELECT
        o.request_id,
        o.emp_id,
        o.ot_date,
        employee.employee_key,
        employee.department_key,
        calendar.date_key,
        o.requested_hours,
        o.approved_hours,
        o.approver_id,
        o.requested_at

    INTO #approved_ot_fact

    FROM staging.overtime_requests AS o

    LEFT JOIN warehouse.dim_employee AS employee
        ON o.emp_id = employee.emp_id
       AND o.ot_date >= employee.valid_from
       AND (
           employee.valid_to IS NULL
           OR o.ot_date <= employee.valid_to
       )

    LEFT JOIN warehouse.dim_date AS calendar
        ON o.ot_date = calendar.calendar_date

    WHERE o.status = 'Approved';


    -- 2. Validate dimension coverage and request grain.
    IF EXISTS (
        SELECT 1
        FROM #approved_ot_fact
        WHERE employee_key IS NULL
           OR department_key IS NULL
           OR date_key IS NULL
           OR approved_hours IS NULL
           OR approved_hours < 0
    )
    BEGIN
        SELECT TOP (20)
            request_id,
            emp_id,
            ot_date,
            employee_key,
            department_key,
            date_key,
            approved_hours
        FROM #approved_ot_fact
        WHERE employee_key IS NULL
           OR department_key IS NULL
           OR date_key IS NULL
           OR approved_hours IS NULL
           OR approved_hours < 0;

        THROW 50221, 'Approved overtime fact validation failed.', 1;
    END;

    IF EXISTS (
        SELECT request_id
        FROM #approved_ot_fact
        GROUP BY request_id
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50222, 'Multiple dimension matches for an overtime request.', 1;


    -- 3. Create the fact with enforced foreign keys.
    IF OBJECT_ID(N'warehouse.fact_overtime_approved', N'U') IS NULL
    BEGIN
        CREATE TABLE warehouse.fact_overtime_approved (
            request_id NVARCHAR(100) NOT NULL PRIMARY KEY,
            employee_key INT NOT NULL,
            date_key INT NOT NULL,
            department_key INT NOT NULL,
            requested_hours DECIMAL(12, 2) NOT NULL,
            approved_hours DECIMAL(12, 2) NOT NULL,
            approver_id NVARCHAR(100) NULL,
            requested_at DATETIME2(6) NOT NULL,

            FOREIGN KEY (employee_key)
                REFERENCES warehouse.dim_employee(employee_key),

            FOREIGN KEY (date_key)
                REFERENCES warehouse.dim_date(date_key),

            FOREIGN KEY (department_key)
                REFERENCES warehouse.dim_department(department_key),

            CHECK (requested_hours >= 0),
            CHECK (approved_hours >= 0)
        );

        CREATE INDEX IX_approved_ot_employee_date
            ON warehouse.fact_overtime_approved (
                employee_key, date_key
            );
    END;


    -- 4. Rebuild approved requests only.
    DELETE FROM warehouse.fact_overtime_approved;

    INSERT INTO warehouse.fact_overtime_approved (
        request_id,
        employee_key,
        date_key,
        department_key,
        requested_hours,
        approved_hours,
        approver_id,
        requested_at
    )
    SELECT
        request_id,
        employee_key,
        date_key,
        department_key,
        requested_hours,
        approved_hours,
        approver_id,
        requested_at
    FROM #approved_ot_fact;


    -- 5. Reconcile request counts and approved hours.
    DECLARE @staging_count BIGINT = (
        SELECT COUNT_BIG(*)
        FROM staging.overtime_requests
        WHERE status = 'Approved'
    );

    DECLARE @warehouse_count BIGINT = (
        SELECT COUNT_BIG(*)
        FROM warehouse.fact_overtime_approved
    );

    IF @staging_count <> @warehouse_count
        THROW 50223, 'Approved overtime row reconciliation failed.', 1;

    IF (
        SELECT COALESCE(SUM(approved_hours), 0)
        FROM staging.overtime_requests
        WHERE status = 'Approved'
    ) <> (
        SELECT COALESCE(SUM(approved_hours), 0)
        FROM warehouse.fact_overtime_approved
    )
        THROW 50224, 'Approved overtime hours reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @staging_count AS staging_approved_requests,
        @warehouse_count AS warehouse_approved_requests,
        'PASS' AS reconciliation;

    SELECT
        calendar.month_start,
        COUNT_BIG(*) AS approved_requests,
        SUM(fact.approved_hours) AS approved_overtime_hours

    FROM warehouse.fact_overtime_approved AS fact
    INNER JOIN warehouse.dim_date AS calendar
        ON fact.date_key = calendar.date_key

    GROUP BY calendar.month_start
    ORDER BY calendar.month_start;

    DROP TABLE IF EXISTS #approved_ot_fact;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;