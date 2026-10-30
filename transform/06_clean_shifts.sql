USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #shifts;

    -- Validate JSON before extracting fields.
    IF EXISTS (
        SELECT 1
        FROM raw.shifts
        WHERE ISJSON(payload) <> 1
    )
        THROW 50020, 'Invalid JSON in raw.shifts.', 1;

    SELECT
        UPPER(
            NULLIF(LTRIM(RTRIM(
                JSON_VALUE(payload, '$.shift_code')
            )), '')
        ) AS shift_code,

        NULLIF(LTRIM(RTRIM(
            JSON_VALUE(payload, '$.name')
        )), '') AS shift_name,

        TRY_CONVERT(
            TIME(0),
            JSON_VALUE(payload, '$.start_time')
        ) AS start_time,

        TRY_CONVERT(
            TIME(0),
            JSON_VALUE(payload, '$.end_time')
        ) AS end_time,

        CASE JSON_VALUE(payload, '$.crosses_midnight')
            WHEN 'true' THEN CAST(1 AS BIT)
            WHEN 'false' THEN CAST(0 AS BIT)
            ELSE NULL
        END AS crosses_midnight,

        TRY_CONVERT(
            INT,
            JSON_VALUE(payload, '$.grace_minutes')
        ) AS grace_minutes,

        JSON_VALUE(payload, '$.applies_to') AS applies_to,
        _source_row_number

    INTO #shifts
    FROM raw.shifts;

    -- Validate required values and consistency.
    IF EXISTS (
        SELECT 1
        FROM #shifts
        WHERE shift_code IS NULL
           OR shift_name IS NULL
           OR start_time IS NULL
           OR end_time IS NULL
           OR crosses_midnight IS NULL
           OR grace_minutes IS NULL
           OR grace_minutes < 0
           OR start_time = end_time
           OR (crosses_midnight = 1 AND end_time > start_time)
           OR (crosses_midnight = 0 AND end_time < start_time)
           OR LEN(shift_code) > 20
           OR LEN(shift_name) > 100
           OR LEN(applies_to) > 200
    )
        THROW 50021, 'Shift validation failed.', 1;

    IF EXISTS (
        SELECT shift_code
        FROM #shifts
        GROUP BY shift_code
        HAVING COUNT(*) > 1
    )
        THROW 50022, 'Duplicate shift codes found.', 1;

    IF OBJECT_ID(N'staging.shifts', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.shifts (
            shift_code NVARCHAR(20) NOT NULL PRIMARY KEY,
            shift_name NVARCHAR(100) NOT NULL,
            start_time TIME(0) NOT NULL,
            end_time TIME(0) NOT NULL,
            crosses_midnight BIT NOT NULL,
            grace_minutes INT NOT NULL,
            applies_to NVARCHAR(200) NULL,
            _source_row_number BIGINT NOT NULL,

            CHECK (grace_minutes >= 0)
        );
    END;

    DELETE FROM staging.shifts;

    INSERT INTO staging.shifts (
        shift_code,
        shift_name,
        start_time,
        end_time,
        crosses_midnight,
        grace_minutes,
        applies_to,
        _source_row_number
    )
    SELECT
        shift_code,
        shift_name,
        start_time,
        end_time,
        crosses_midnight,
        grace_minutes,
        applies_to,
        _source_row_number
    FROM #shifts;

    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.shifts);

    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.shifts);

    IF @raw_count <> @staging_count
        THROW 50023, 'Shift reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @raw_count AS raw_records,
        @staging_count AS staging_records,
        'PASS' AS reconciliation;

    SELECT
        shift_code,
        start_time,
        end_time,
        crosses_midnight,
        grace_minutes
    FROM staging.shifts
    ORDER BY shift_code;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;