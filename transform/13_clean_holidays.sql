USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #holidays;

    SELECT
        TRY_CONVERT(
            DATE,
            NULLIF(LTRIM(RTRIM(holiday_date)), ''),
            23
        ) AS holiday_date,

        NULLIF(
            LTRIM(RTRIM(holiday_name)), ''
        ) AS holiday_name,

        UPPER(
            NULLIF(LTRIM(RTRIM(scope)), '')
        ) AS scope,

        _source_row_number

    INTO #holidays
    FROM raw.holidays;

    -- Validate dates, names, scopes, and target lengths.
    IF EXISTS (
        SELECT 1
        FROM #holidays
        WHERE holiday_date IS NULL
           OR holiday_name IS NULL
           OR scope IS NULL
           OR scope NOT IN ('ALL', 'HO', 'KOR', 'SITE', 'FSD')
           OR LEN(holiday_name) > 200
    )
        THROW 50080, 'Holiday validation failed.', 1;

    -- A holiday is identified by its date and scope.
    IF EXISTS (
        SELECT holiday_date, scope
        FROM #holidays
        GROUP BY holiday_date, scope
        HAVING COUNT(*) > 1
    )
        THROW 50081, 'Duplicate holiday date/scope requires review.', 1;

    IF OBJECT_ID(N'staging.holidays', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.holidays (
            holiday_date DATE NOT NULL,
            holiday_name NVARCHAR(200) NOT NULL,
            scope NVARCHAR(10) NOT NULL,
            _source_row_number BIGINT NOT NULL UNIQUE,

            PRIMARY KEY (holiday_date, scope),

            CHECK (
                scope IN ('ALL', 'HO', 'KOR', 'SITE', 'FSD')
            )
        );
    END;

    DELETE FROM staging.holidays;

    INSERT INTO staging.holidays (
        holiday_date,
        holiday_name,
        scope,
        _source_row_number
    )
    SELECT
        holiday_date,
        holiday_name,
        scope,
        _source_row_number
    FROM #holidays;

    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.holidays);

    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.holidays);

    IF @raw_count <> @staging_count
        THROW 50082, 'Holiday reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @raw_count AS raw_records,
        @staging_count AS staging_records,
        'PASS' AS reconciliation;

    SELECT
        holiday_date,
        holiday_name,
        scope
    FROM staging.holidays
    ORDER BY holiday_date, scope;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;