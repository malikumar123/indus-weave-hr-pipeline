USE [indus_weave_hr_pipeline];
GO

-- Month names such as "Nov" are English in the source.
SET LANGUAGE us_english;
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Remove temporary tables if this session ran the script before.
    DROP TABLE IF EXISTS #prepared;
    DROP TABLE IF EXISTS #ranked;

    -- Step 1: Trim text and convert source values.
    SELECT
        NULLIF(LTRIM(RTRIM(emp_id)), '') AS emp_id,
        LTRIM(RTRIM(full_name)) AS full_name,
        LTRIM(RTRIM(gender)) AS gender,

        COALESCE(
            TRY_CONVERT(DATE, NULLIF(date_of_birth, ''), 23),
            TRY_CONVERT(DATE, NULLIF(date_of_birth, ''), 103),
            TRY_CONVERT(DATE, NULLIF(date_of_birth, ''), 106)
        ) AS date_of_birth,

        LTRIM(RTRIM(email)) AS email,
        LTRIM(RTRIM(phone)) AS phone,

        COALESCE(
            TRY_CONVERT(DATE, NULLIF(hire_date, ''), 23),
            TRY_CONVERT(DATE, NULLIF(hire_date, ''), 103),
            TRY_CONVERT(DATE, NULLIF(hire_date, ''), 106)
        ) AS hire_date,

        COALESCE(
            TRY_CONVERT(DATE, NULLIF(separation_date, ''), 23),
            TRY_CONVERT(DATE, NULLIF(separation_date, ''), 103),
            TRY_CONVERT(DATE, NULLIF(separation_date, ''), 106)
        ) AS separation_date,

        LTRIM(RTRIM(plant)) AS plant,
        LTRIM(RTRIM(department)) AS department,
        LTRIM(RTRIM(designation)) AS designation,
        UPPER(LTRIM(RTRIM(grade))) AS grade,
        LTRIM(RTRIM(employment_type)) AS employment_type,
        LTRIM(RTRIM(status)) AS status,

        TRY_CONVERT(
            INT, NULLIF(LTRIM(RTRIM(annual_leave_entitlement)), '')
        ) AS annual_leave_entitlement,

        TRY_CONVERT(
            DATETIME2(6), NULLIF(LTRIM(RTRIM(updated_at)), ''), 126
        ) AS updated_at,

        _source_file,
        _source_row_number,

        -- Keep this flag to distinguish an empty separation date
        -- from a nonempty date that failed conversion.
        CASE
            WHEN NULLIF(LTRIM(RTRIM(separation_date)), '') IS NOT NULL
            THEN 1
            ELSE 0
        END AS had_separation_date

    INTO #prepared
    FROM raw.employees;

    -- Step 2: Stop rather than silently accept invalid conversions.
    IF EXISTS (
        SELECT 1
        FROM #prepared
        WHERE emp_id IS NULL
           OR date_of_birth IS NULL
           OR hire_date IS NULL
           OR updated_at IS NULL
           OR annual_leave_entitlement IS NULL
           OR annual_leave_entitlement < 0
           OR (
               had_separation_date = 1
               AND separation_date IS NULL
           )
           OR separation_date < hire_date
    )
    BEGIN
        SELECT *
        FROM #prepared
        WHERE emp_id IS NULL
           OR date_of_birth IS NULL
           OR hire_date IS NULL
           OR updated_at IS NULL
           OR annual_leave_entitlement IS NULL
           OR annual_leave_entitlement < 0
           OR (
               had_separation_date = 1
               AND separation_date IS NULL
           )
           OR separation_date < hire_date;

        THROW 50001, 'Employee validation failed. Review returned records.', 1;
    END;

    -- Step 3: Rank employee versions by actual update timestamp.
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id
            ORDER BY updated_at DESC, _source_row_number DESC
        ) AS version_rank,

        FIRST_VALUE(_source_row_number) OVER (
            PARTITION BY emp_id
            ORDER BY updated_at DESC, _source_row_number DESC
        ) AS retained_source_row_number

    INTO #ranked
    FROM #prepared;

    -- Step 4: Create the typed employee table on the first run.
    IF OBJECT_ID(N'staging.employees', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.employees (
            emp_id NVARCHAR(50) NOT NULL PRIMARY KEY,
            full_name NVARCHAR(MAX) NULL,
            gender NVARCHAR(MAX) NULL,
            date_of_birth DATE NOT NULL,
            email NVARCHAR(MAX) NULL,
            phone NVARCHAR(MAX) NULL,
            hire_date DATE NOT NULL,
            separation_date DATE NULL,
            plant NVARCHAR(MAX) NULL,
            department NVARCHAR(MAX) NULL,
            designation NVARCHAR(MAX) NULL,
            grade NVARCHAR(MAX) NULL,
            employment_type NVARCHAR(MAX) NULL,
            status NVARCHAR(MAX) NULL,
            annual_leave_entitlement INT NOT NULL,
            updated_at DATETIME2(6) NOT NULL,
            _source_file NVARCHAR(255) NOT NULL,
            _source_row_number BIGINT NOT NULL
        );
    END;

    IF OBJECT_ID(N'staging.employee_merge_log', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.employee_merge_log (
            emp_id NVARCHAR(50) NOT NULL,
            discarded_source_row_number BIGINT NOT NULL PRIMARY KEY,
            retained_source_row_number BIGINT NOT NULL,
            discarded_updated_at DATETIME2(6) NOT NULL,
            reason NVARCHAR(255) NOT NULL
        );
    END;

    -- Rebuild these outputs safely inside this transaction.
    DELETE FROM staging.employee_merge_log;
    DELETE FROM staging.employees;

    INSERT INTO staging.employees (
        emp_id, full_name, gender, date_of_birth,
        email, phone, hire_date, separation_date,
        plant, department, designation, grade,
        employment_type, status, annual_leave_entitlement,
        updated_at, _source_file, _source_row_number
    )
    SELECT
        emp_id, full_name, gender, date_of_birth,
        email, phone, hire_date, separation_date,
        plant, department, designation, grade,
        employment_type, status, annual_leave_entitlement,
        updated_at, _source_file, _source_row_number
    FROM #ranked
    WHERE version_rank = 1;

    INSERT INTO staging.employee_merge_log (
        emp_id,
        discarded_source_row_number,
        retained_source_row_number,
        discarded_updated_at,
        reason
    )
    SELECT
        emp_id,
        _source_row_number,
        retained_source_row_number,
        updated_at,
        'Latest updated_at retained; ties use greatest source row number'
    FROM #ranked
    WHERE version_rank > 1;

    -- Step 5: Every raw employee record must be accounted for.
    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.employees);

    DECLARE @retained_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.employees);

    DECLARE @merged_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.employee_merge_log);

    IF @raw_count <> @retained_count + @merged_count
        THROW 50002, 'Employee record reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @raw_count AS raw_records,
        @retained_count AS retained_employees,
        @merged_count AS discarded_versions,
        'PASS' AS reconciliation;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;