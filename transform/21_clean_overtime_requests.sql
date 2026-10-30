USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #overtime_requests;

    -- 1. Clean text and convert dates and hours.
    SELECT
        NULLIF(LTRIM(RTRIM(request_id)), '') AS request_id,
        NULLIF(LTRIM(RTRIM(emp_id)), '') AS emp_id,

        TRY_CONVERT(
            DATE,
            NULLIF(LTRIM(RTRIM(ot_date)), ''),
            23
        ) AS ot_date,

        TRY_CONVERT(
            DECIMAL(12, 2),
            NULLIF(LTRIM(RTRIM(requested_hours)), '')
        ) AS requested_hours,

        TRY_CONVERT(
            DECIMAL(12, 2),
            NULLIF(LTRIM(RTRIM(approved_hours)), '')
        ) AS approved_hours,

        UPPER(
            NULLIF(LTRIM(RTRIM(status)), '')
        ) AS normalized_status,

        NULLIF(LTRIM(RTRIM(approver_id)), '') AS approver_id,

        TRY_CONVERT(
            DATETIME2(6),
            NULLIF(LTRIM(RTRIM(requested_at)), ''),
            126
        ) AS requested_at,

        CASE
            WHEN NULLIF(LTRIM(RTRIM(approved_hours)), '') IS NOT NULL
            THEN 1 ELSE 0
        END AS had_approved_hours,

        _source_row_number

    INTO #overtime_requests
    FROM raw.overtime_requests;


    -- 2. Validate values without discarding nonapproved requests.
    IF EXISTS (
        SELECT 1
        FROM #overtime_requests
        WHERE request_id IS NULL
           OR emp_id IS NULL
           OR ot_date IS NULL
           OR requested_hours IS NULL
           OR requested_hours < 0
           OR requested_at IS NULL
           OR normalized_status IS NULL
           OR normalized_status NOT IN (
               'APPROVED', 'REJECTED', 'PENDING'
           )
           OR (had_approved_hours = 1 AND approved_hours IS NULL)
           OR approved_hours < 0
           OR (
               normalized_status = 'APPROVED'
               AND approved_hours IS NULL
           )
           OR LEN(request_id) > 100
           OR LEN(emp_id) > 50
           OR LEN(approver_id) > 100
    )
        THROW 50140, 'Invalid overtime request values.', 1;

    IF EXISTS (
        SELECT request_id
        FROM #overtime_requests
        GROUP BY request_id
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50141, 'Duplicate overtime request IDs found.', 1;

    IF EXISTS (
        SELECT 1
        FROM #overtime_requests AS o
        LEFT JOIN staging.employees AS e
            ON o.emp_id = e.emp_id
        WHERE e.emp_id IS NULL
    )
        THROW 50142, 'Overtime request references an unknown employee.', 1;


    -- 3. Create a typed staging table.
    IF OBJECT_ID(N'staging.overtime_requests', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.overtime_requests (
            request_id NVARCHAR(100) NOT NULL PRIMARY KEY,
            emp_id NVARCHAR(50) NOT NULL,
            ot_date DATE NOT NULL,
            requested_hours DECIMAL(12, 2) NOT NULL,
            approved_hours DECIMAL(12, 2) NULL,
            status NVARCHAR(20) NOT NULL,
            approver_id NVARCHAR(100) NULL,
            requested_at DATETIME2(6) NOT NULL,
            _source_row_number BIGINT NOT NULL UNIQUE,

            CHECK (requested_hours >= 0),

            CHECK (
                approved_hours IS NULL
                OR approved_hours >= 0
            ),

            CHECK (status IN ('Approved', 'Rejected', 'Pending')),

            CHECK (
                status <> 'Approved'
                OR approved_hours IS NOT NULL
            )
        );

        CREATE INDEX IX_overtime_employee_date
            ON staging.overtime_requests (emp_id, ot_date)
            INCLUDE (status, approved_hours);
    END;


    -- 4. Rebuild while preserving every source request.
    DELETE FROM staging.overtime_requests;

    INSERT INTO staging.overtime_requests (
        request_id,
        emp_id,
        ot_date,
        requested_hours,
        approved_hours,
        status,
        approver_id,
        requested_at,
        _source_row_number
    )
    SELECT
        request_id,
        emp_id,
        ot_date,
        requested_hours,
        approved_hours,

        CASE normalized_status
            WHEN 'APPROVED' THEN 'Approved'
            WHEN 'REJECTED' THEN 'Rejected'
            WHEN 'PENDING' THEN 'Pending'
        END,

        approver_id,
        requested_at,
        _source_row_number
    FROM #overtime_requests;


    -- 5. Reconcile source and staging counts.
    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.overtime_requests);

    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.overtime_requests);

    IF @raw_count <> @staging_count
        THROW 50143, 'Overtime request reconciliation failed.', 1;

    COMMIT TRANSACTION;

    -- Result A: Reconciliation.
    SELECT
        @raw_count AS raw_records,
        @staging_count AS staging_records,
        'PASS' AS reconciliation;

    -- Result B: Request status distribution.
    SELECT
        status,
        COUNT_BIG(*) AS request_count
    FROM staging.overtime_requests
    GROUP BY status
    ORDER BY status;

    -- Result C: Approved hours by shift-date month.
    SELECT
        DATEFROMPARTS(
            YEAR(ot_date),
            MONTH(ot_date),
            1
        ) AS month_start,

        COUNT_BIG(*) AS approved_requests,
        SUM(approved_hours) AS approved_overtime_hours

    FROM staging.overtime_requests
    WHERE status = 'Approved'
    GROUP BY YEAR(ot_date), MONTH(ot_date)
    ORDER BY month_start;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;