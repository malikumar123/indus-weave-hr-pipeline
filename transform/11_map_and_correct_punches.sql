USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #prepared_punches;

    -- Clock rule inferred from monthly and daily arrival comparisons.
    DECLARE @affected_device NVARCHAR(100) = 'DEV-SITE-01';
    DECLARE @correction_start DATETIME2(6) = '2026-07-01T00:00:00';
    DECLARE @adjustment_minutes INT = -60;

    -- 1. Parse source values and map using both device keys.
    WITH parsed AS (
        SELECT
            NULLIF(LTRIM(RTRIM(p.punch_id)), '') AS punch_id,
            NULLIF(LTRIM(RTRIM(p.device_id)), '') AS device_id,
            NULLIF(LTRIM(RTRIM(p.device_user_id)), '')
                AS device_user_id,

            p.punch_time AS source_punch_time,

            TRY_CONVERT(
                DATETIME2(6),
                NULLIF(LTRIM(RTRIM(p.punch_time)), ''),
                126
            ) AS original_punch_time,

            p._source_file,
            p._source_row_number

        FROM raw.biometric_punches AS p
    ),
    mapped AS (
        SELECT
            p.*,
            m.emp_id,

            CASE
                WHEN p.device_id = @affected_device
                 AND p.original_punch_time >= @correction_start
                THEN @adjustment_minutes
                ELSE 0
            END AS clock_adjustment_minutes,

            CASE
                WHEN p.punch_id IS NULL
                  OR p.device_id IS NULL
                  OR p.device_user_id IS NULL
                    THEN 'Missing required identifier'
                WHEN p.original_punch_time IS NULL
                    THEN 'Invalid punch timestamp'
                WHEN m.emp_id IS NULL
                    THEN 'No device/user mapping'
                ELSE NULL
            END AS rejection_reason

        FROM parsed AS p
        LEFT JOIN staging.device_mapping AS m
            ON p.device_id = m.device_id
           AND p.device_user_id = m.device_user_id
    )
    SELECT
        *,
        DATEADD(
            MINUTE,
            clock_adjustment_minutes,
            original_punch_time
        ) AS corrected_punch_time

    INTO #prepared_punches
    FROM mapped;

    -- Validate target lengths before inserting accepted records.
    IF EXISTS (
        SELECT 1
        FROM #prepared_punches
        WHERE rejection_reason IS NULL
          AND (
              LEN(punch_id) > 100
              OR LEN(device_id) > 100
              OR LEN(device_user_id) > 100
              OR LEN(emp_id) > 50
          )
    )
        THROW 50060, 'Punch identifier exceeds target length.', 1;

    -- Duplicate punch IDs need investigation; near-time duplicates
    -- with different IDs will be handled in the next stage.
    IF EXISTS (
        SELECT punch_id
        FROM #prepared_punches
        WHERE rejection_reason IS NULL
        GROUP BY punch_id
        HAVING COUNT(*) > 1
    )
        THROW 50061, 'Repeated punch IDs require review.', 1;

    -- 2. Create the accepted and rejected output tables.
    IF OBJECT_ID(N'staging.mapped_punches', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.mapped_punches (
            punch_id NVARCHAR(100) NOT NULL PRIMARY KEY,
            emp_id NVARCHAR(50) NOT NULL,
            device_id NVARCHAR(100) NOT NULL,
            device_user_id NVARCHAR(100) NOT NULL,
            original_punch_time DATETIME2(6) NOT NULL,
            corrected_punch_time DATETIME2(6) NOT NULL,
            clock_adjustment_minutes INT NOT NULL,
            _source_file NVARCHAR(255) NOT NULL,
            _source_row_number BIGINT NOT NULL UNIQUE
        );

        CREATE INDEX IX_mapped_punches_employee_time
            ON staging.mapped_punches (
                emp_id,
                corrected_punch_time,
                _source_row_number
            );
    END;

    IF OBJECT_ID(N'staging.rejected_punches', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.rejected_punches (
            _source_row_number BIGINT NOT NULL PRIMARY KEY,
            _source_file NVARCHAR(255) NOT NULL,
            punch_id NVARCHAR(MAX) NULL,
            device_id NVARCHAR(MAX) NULL,
            device_user_id NVARCHAR(MAX) NULL,
            source_punch_time NVARCHAR(MAX) NULL,
            rejection_reason NVARCHAR(200) NOT NULL
        );
    END;

    -- 3. Rebuild from raw, so corrections cannot accumulate on reruns.
    DELETE FROM staging.mapped_punches;
    DELETE FROM staging.rejected_punches;

    INSERT INTO staging.mapped_punches (
        punch_id,
        emp_id,
        device_id,
        device_user_id,
        original_punch_time,
        corrected_punch_time,
        clock_adjustment_minutes,
        _source_file,
        _source_row_number
    )
    SELECT
        punch_id,
        emp_id,
        device_id,
        device_user_id,
        original_punch_time,
        corrected_punch_time,
        clock_adjustment_minutes,
        _source_file,
        _source_row_number
    FROM #prepared_punches
    WHERE rejection_reason IS NULL;

    INSERT INTO staging.rejected_punches (
        _source_row_number,
        _source_file,
        punch_id,
        device_id,
        device_user_id,
        source_punch_time,
        rejection_reason
    )
    SELECT
        _source_row_number,
        _source_file,
        punch_id,
        device_id,
        device_user_id,
        source_punch_time,
        rejection_reason
    FROM #prepared_punches
    WHERE rejection_reason IS NOT NULL;

    -- 4. Reconcile every source record.
    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.biometric_punches);

    DECLARE @mapped_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.mapped_punches);

    DECLARE @rejected_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.rejected_punches);

    IF @raw_count <> @mapped_count + @rejected_count
        THROW 50062, 'Punch reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @raw_count AS raw_punches,
        @mapped_count AS mapped_punches,
        @rejected_count AS rejected_punches,
        'PASS' AS reconciliation;

    SELECT
        device_id,
        clock_adjustment_minutes,
        COUNT_BIG(*) AS punch_count
    FROM staging.mapped_punches
    GROUP BY device_id, clock_adjustment_minutes
    ORDER BY device_id, clock_adjustment_minutes;

    SELECT
        rejection_reason,
        COUNT_BIG(*) AS rejected_count
    FROM staging.rejected_punches
    GROUP BY rejection_reason;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;