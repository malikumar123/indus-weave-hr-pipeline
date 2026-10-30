USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #classified_punches;

    -- 1. Compare each corrected punch with the preceding punch
    -- for the same employee.
    WITH previous_punches AS (
        SELECT
            p.*,

            LAG(corrected_punch_time) OVER (
                PARTITION BY emp_id
                ORDER BY
                    corrected_punch_time,
                    _source_row_number
            ) AS previous_punch_time

        FROM staging.mapped_punches AS p
    ),
    group_boundaries AS (
        SELECT
            *,

            CASE
                WHEN previous_punch_time IS NULL THEN 1

                WHEN corrected_punch_time >
                     DATEADD(SECOND, 120, previous_punch_time)
                    THEN 1

                ELSE 0
            END AS starts_new_group

        FROM previous_punches
    ),
    numbered_groups AS (
        SELECT
            *,

            SUM(CAST(starts_new_group AS BIGINT)) OVER (
                PARTITION BY emp_id
                ORDER BY
                    corrected_punch_time,
                    _source_row_number
                ROWS UNBOUNDED PRECEDING
            ) AS duplicate_group

        FROM group_boundaries
    )
    SELECT
        *,

        FIRST_VALUE(_source_row_number) OVER (
            PARTITION BY emp_id, duplicate_group
            ORDER BY
                corrected_punch_time,
                _source_row_number
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND UNBOUNDED FOLLOWING
        ) AS retained_source_row_number

    INTO #classified_punches
    FROM numbered_groups;


    -- 2. Create the cleaned punch table.
    IF OBJECT_ID(N'staging.biometric_punches', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.biometric_punches (
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

        CREATE INDEX IX_clean_punches_employee_time
            ON staging.biometric_punches (
                emp_id,
                corrected_punch_time,
                _source_row_number
            );
    END;

    -- Excluded records remain traceable to staging.mapped_punches.
    IF OBJECT_ID(N'staging.punch_duplicate_log', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.punch_duplicate_log (
            discarded_source_row_number BIGINT NOT NULL PRIMARY KEY,
            retained_source_row_number BIGINT NOT NULL,
            emp_id NVARCHAR(50) NOT NULL,
            punch_id NVARCHAR(100) NOT NULL,
            corrected_punch_time DATETIME2(6) NOT NULL,
            reason NVARCHAR(255) NOT NULL
        );
    END;


    -- 3. Rebuild outputs safely.
    DELETE FROM staging.punch_duplicate_log;
    DELETE FROM staging.biometric_punches;

    INSERT INTO staging.biometric_punches (
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
    FROM #classified_punches
    WHERE _source_row_number = retained_source_row_number;

    INSERT INTO staging.punch_duplicate_log (
        discarded_source_row_number,
        retained_source_row_number,
        emp_id,
        punch_id,
        corrected_punch_time,
        reason
    )
    SELECT
        _source_row_number,
        retained_source_row_number,
        emp_id,
        punch_id,
        corrected_punch_time,
        'Consecutive employee punches within 120 seconds; earliest retained'
    FROM #classified_punches
    WHERE _source_row_number <> retained_source_row_number;


    -- 4. Every exclusion must point to a retained punch.
    IF EXISTS (
        SELECT 1
        FROM staging.punch_duplicate_log AS d
        LEFT JOIN staging.biometric_punches AS p
            ON d.retained_source_row_number = p._source_row_number
           AND d.emp_id = p.emp_id
        WHERE p._source_row_number IS NULL
    )
        THROW 50070, 'Duplicate log references a missing retained punch.', 1;


    -- 5. Verify retained punches are more than two minutes apart.
    IF EXISTS (
        SELECT 1
        FROM (
            SELECT
                corrected_punch_time,

                LAG(corrected_punch_time) OVER (
                    PARTITION BY emp_id
                    ORDER BY
                        corrected_punch_time,
                        _source_row_number
                ) AS previous_time

            FROM staging.biometric_punches
        ) AS checked
        WHERE corrected_punch_time <=
              DATEADD(SECOND, 120, previous_time)
    )
        THROW 50071, 'Near-time duplicates remain in cleaned punches.', 1;


    -- 6. Reconcile both transformation steps.
    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.biometric_punches);

    DECLARE @mapped_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.mapped_punches);

    DECLARE @clean_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.biometric_punches);

    DECLARE @duplicate_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.punch_duplicate_log);

    DECLARE @rejected_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.rejected_punches);

    IF @mapped_count <> @clean_count + @duplicate_count
        THROW 50072, 'Mapped punch reconciliation failed.', 1;

    IF @raw_count <> @clean_count + @duplicate_count + @rejected_count
        THROW 50073, 'Raw punch reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @raw_count AS raw_punches,
        @clean_count AS retained_punches,
        @duplicate_count AS duplicate_punches,
        @rejected_count AS rejected_punches,
        'PASS' AS reconciliation;

    SELECT TOP (10)
        emp_id,
        punch_id,
        corrected_punch_time,
        discarded_source_row_number,
        retained_source_row_number
    FROM staging.punch_duplicate_log
    ORDER BY emp_id, corrected_punch_time;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;