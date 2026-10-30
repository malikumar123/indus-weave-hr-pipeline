USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #device_mapping;

    SELECT
        NULLIF(LTRIM(RTRIM(device_id)), '') AS device_id,
        NULLIF(LTRIM(RTRIM(device_user_id)), '') AS device_user_id,
        NULLIF(LTRIM(RTRIM(emp_id)), '') AS emp_id,

        TRY_CONVERT(
            DATE,
            NULLIF(LTRIM(RTRIM(enrolled_on)), ''),
            23
        ) AS enrolled_on,

        _source_row_number

    INTO #device_mapping
    FROM raw.device_mapping;

    -- Validate required fields and target lengths.
    IF EXISTS (
        SELECT 1
        FROM #device_mapping
        WHERE device_id IS NULL
           OR device_user_id IS NULL
           OR emp_id IS NULL
           OR enrolled_on IS NULL
           OR LEN(device_id) > 100
           OR LEN(device_user_id) > 100
           OR LEN(emp_id) > 50
    )
        THROW 50040, 'Invalid device mapping values.', 1;

    -- The combination must identify exactly one mapping.
    IF EXISTS (
        SELECT device_id, device_user_id
        FROM #device_mapping
        GROUP BY device_id, device_user_id
        HAVING COUNT(*) > 1
    )
        THROW 50041, 'Duplicate device/user mapping found.', 1;

    IF EXISTS (
        SELECT 1
        FROM #device_mapping AS m
        LEFT JOIN staging.employees AS e
            ON m.emp_id = e.emp_id
        WHERE e.emp_id IS NULL
    )
        THROW 50042, 'Device mapping references an unknown employee.', 1;

    IF OBJECT_ID(N'staging.device_mapping', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.device_mapping (
            device_id NVARCHAR(100) NOT NULL,
            device_user_id NVARCHAR(100) NOT NULL,
            emp_id NVARCHAR(50) NOT NULL,
            enrolled_on DATE NOT NULL,
            _source_row_number BIGINT NOT NULL,

            PRIMARY KEY (device_id, device_user_id)
        );
    END;

    DELETE FROM staging.device_mapping;

    INSERT INTO staging.device_mapping (
        device_id,
        device_user_id,
        emp_id,
        enrolled_on,
        _source_row_number
    )
    SELECT
        device_id,
        device_user_id,
        emp_id,
        enrolled_on,
        _source_row_number
    FROM #device_mapping;

    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.device_mapping);

    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.device_mapping);

    IF @raw_count <> @staging_count
        THROW 50043, 'Device mapping reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @raw_count AS raw_records,
        @staging_count AS staging_records,
        'PASS' AS reconciliation;

    SELECT
        device_id,
        COUNT_BIG(*) AS mapped_users
    FROM staging.device_mapping
    GROUP BY device_id
    ORDER BY device_id;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;