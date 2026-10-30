USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #departments;

    -- Clean text and convert the optional rename date.
    SELECT
        NULLIF(LTRIM(RTRIM(dept_id)), '') AS dept_id,
        NULLIF(LTRIM(RTRIM(dept_name)), '') AS dept_name,
        NULLIF(LTRIM(RTRIM(plant)), '') AS plant,
        NULLIF(LTRIM(RTRIM(cost_center)), '') AS cost_center,
        NULLIF(LTRIM(RTRIM(previous_name)), '') AS previous_name,

        TRY_CONVERT(
            DATE,
            NULLIF(LTRIM(RTRIM(renamed_on)), ''),
            23
        ) AS renamed_on,

        _source_row_number,

        CASE
            WHEN NULLIF(LTRIM(RTRIM(renamed_on)), '') IS NOT NULL
            THEN 1
            ELSE 0
        END AS had_rename_date

    INTO #departments
    FROM raw.departments;

    -- Validate required fields and rename information.
    IF EXISTS (
        SELECT 1
        FROM #departments
        WHERE dept_id IS NULL
           OR dept_name IS NULL
           OR plant IS NULL
           OR cost_center IS NULL
           OR (had_rename_date = 1 AND renamed_on IS NULL)
           OR (previous_name IS NOT NULL AND renamed_on IS NULL)
           OR (previous_name IS NULL AND renamed_on IS NOT NULL)
    )
        THROW 50003, 'Department validation failed.', 1;

    IF EXISTS (
        SELECT dept_id
        FROM #departments
        GROUP BY dept_id
        HAVING COUNT(*) > 1
    )
        THROW 50004, 'Duplicate department IDs found.', 1;

    -- Check lengths before inserting into bounded text columns.
    IF EXISTS (
        SELECT 1
        FROM #departments
        WHERE LEN(dept_id) > 50
           OR LEN(dept_name) > 200
           OR LEN(plant) > 100
           OR LEN(cost_center) > 100
           OR LEN(previous_name) > 200
    )
        THROW 50005, 'Department value exceeds target column length.', 1;

    IF OBJECT_ID(N'staging.departments', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.departments (
            dept_id NVARCHAR(50) NOT NULL PRIMARY KEY,
            dept_name NVARCHAR(200) NOT NULL,
            plant NVARCHAR(100) NOT NULL,
            cost_center NVARCHAR(100) NOT NULL,
            previous_name NVARCHAR(200) NULL,
            renamed_on DATE NULL,
            _source_row_number BIGINT NOT NULL
        );
    END;

    DELETE FROM staging.departments;

    INSERT INTO staging.departments (
        dept_id,
        dept_name,
        plant,
        cost_center,
        previous_name,
        renamed_on,
        _source_row_number
    )
    SELECT
        dept_id,
        dept_name,
        plant,
        cost_center,
        previous_name,
        renamed_on,
        _source_row_number
    FROM #departments;

    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.departments);

    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.departments);

    IF @raw_count <> @staging_count
        THROW 50006, 'Department reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @raw_count AS raw_records,
        @staging_count AS staging_records,
        'PASS' AS reconciliation;

    SELECT
        dept_id,
        plant,
        previous_name,
        dept_name AS current_name,
        renamed_on
    FROM staging.departments
    WHERE previous_name IS NOT NULL
    ORDER BY dept_id;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;