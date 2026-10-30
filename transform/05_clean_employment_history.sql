USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #prepared_history;
    DROP TABLE IF EXISTS #ranked_history;
    DROP TABLE IF EXISTS #final_history;

    -- 1. Convert source values without trusting effective_to.
    SELECT
        NULLIF(LTRIM(RTRIM(emp_id)), '') AS emp_id,

        TRY_CONVERT(
            DATE,
            NULLIF(LTRIM(RTRIM(effective_from)), ''),
            23
        ) AS effective_from,

        -- Preserve the exported end date for auditing.
        effective_to AS source_effective_to,

        NULLIF(LTRIM(RTRIM(dept_id)), '') AS dept_id,
        NULLIF(LTRIM(RTRIM(designation)), '') AS designation,
        UPPER(NULLIF(LTRIM(RTRIM(grade)), '')) AS grade,

        TRY_CONVERT(
            DECIMAL(18, 2),
            NULLIF(LTRIM(RTRIM(basic_salary)), '')
        ) AS basic_salary,

        NULLIF(LTRIM(RTRIM(change_reason)), '') AS change_reason,

        _source_file,
        _source_row_number

    INTO #prepared_history
    FROM raw.employment_history;


    -- 2. Validate required fields and column lengths.
    IF EXISTS (
        SELECT 1
        FROM #prepared_history
        WHERE emp_id IS NULL
           OR effective_from IS NULL
           OR dept_id IS NULL
           OR designation IS NULL
           OR grade IS NULL
           OR basic_salary IS NULL
           OR basic_salary < 0
           OR change_reason IS NULL
           OR change_reason NOT IN (
               'Hire', 'Salary Revision', 'Promotion', 'Transfer'
           )
           OR LEN(emp_id) > 50
           OR LEN(dept_id) > 50
           OR LEN(designation) > 200
           OR LEN(grade) > 20
           OR LEN(change_reason) > 50
    )
        THROW 50010, 'Invalid employment history values.', 1;


    -- 3. Check references against cleaned employees and departments.
    IF EXISTS (
        SELECT 1
        FROM #prepared_history AS h
        LEFT JOIN staging.employees AS e
            ON h.emp_id = e.emp_id
        LEFT JOIN staging.departments AS d
            ON h.dept_id = d.dept_id
        WHERE e.emp_id IS NULL
           OR d.dept_id IS NULL
    )
        THROW 50011, 'History contains unknown employee or department IDs.', 1;


    -- 4. Allow only the reviewed same-day conflict pattern:
    -- one Hire and one Salary Revision.
    -- Other conflicts must be reviewed instead of silently resolved.
    IF EXISTS (
        SELECT
            emp_id,
            effective_from
        FROM #prepared_history
        GROUP BY emp_id, effective_from
        HAVING COUNT(*) > 1
           AND NOT (
               COUNT(*) = 2
               AND SUM(
                   CASE WHEN change_reason = 'Hire' THEN 1 ELSE 0 END
               ) = 1
               AND SUM(
                   CASE WHEN change_reason = 'Salary Revision'
                        THEN 1 ELSE 0 END
               ) = 1
           )
    )
        THROW 50012, 'Unreviewed same-day history conflict found.', 1;


    -- 5. Apply the agreed precedence within each employee/start date.
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY emp_id, effective_from
            ORDER BY
                CASE
                    WHEN change_reason = 'Salary Revision' THEN 1
                    ELSE 2
                END,
                _source_row_number
        ) AS version_rank,

        FIRST_VALUE(_source_row_number) OVER (
            PARTITION BY emp_id, effective_from
            ORDER BY
                CASE
                    WHEN change_reason = 'Salary Revision' THEN 1
                    ELSE 2
                END,
                _source_row_number
        ) AS retained_source_row_number

    INTO #ranked_history
    FROM #prepared_history;


    -- 6. Calculate end dates AFTER resolving same-day records.
    WITH retained_history AS (
        SELECT *
        FROM #ranked_history
        WHERE version_rank = 1
    ),
    next_dates AS (
        SELECT
            *,
            LEAD(effective_from) OVER (
                PARTITION BY emp_id
                ORDER BY effective_from
            ) AS next_effective_from
        FROM retained_history
    )
    SELECT
        emp_id,
        effective_from,
        DATEADD(DAY, -1, next_effective_from) AS effective_to,
        dept_id,
        designation,
        grade,
        basic_salary,
        change_reason,
        source_effective_to,
        _source_file,
        _source_row_number

    INTO #final_history
    FROM next_dates;


    -- 7. Check date ranges and coverage of employee IDs.
    IF EXISTS (
        SELECT 1
        FROM #final_history
        WHERE effective_to < effective_from
    )
        THROW 50013, 'Invalid calculated history range.', 1;

    IF EXISTS (
        SELECT 1
        FROM staging.employees AS e
        WHERE NOT EXISTS (
            SELECT 1
            FROM #final_history AS h
            WHERE h.emp_id = e.emp_id
        )
    )
        THROW 50014, 'An employee has no employment history.', 1;

    IF EXISTS (
        SELECT 1
        FROM #final_history AS a
        INNER JOIN #final_history AS b
            ON a.emp_id = b.emp_id
           AND a.effective_from < b.effective_from
        WHERE a.effective_to IS NULL
           OR a.effective_to >= b.effective_from
    )
        THROW 50015, 'Overlapping history ranges found.', 1;


    -- 8. Create output tables on the first run.
    IF OBJECT_ID(N'staging.employment_history', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.employment_history (
            emp_id NVARCHAR(50) NOT NULL,
            effective_from DATE NOT NULL,
            effective_to DATE NULL,
            dept_id NVARCHAR(50) NOT NULL,
            designation NVARCHAR(200) NOT NULL,
            grade NVARCHAR(20) NOT NULL,
            basic_salary DECIMAL(18, 2) NOT NULL,
            change_reason NVARCHAR(50) NOT NULL,
            source_effective_to NVARCHAR(MAX) NULL,
            _source_file NVARCHAR(255) NOT NULL,
            _source_row_number BIGINT NOT NULL,

            PRIMARY KEY (emp_id, effective_from),

            CHECK (
                effective_to IS NULL
                OR effective_to >= effective_from
            ),

            CHECK (basic_salary >= 0)
        );
    END;

    IF OBJECT_ID(N'staging.history_resolution_log', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.history_resolution_log (
            emp_id NVARCHAR(50) NOT NULL,
            effective_from DATE NOT NULL,
            discarded_source_row_number BIGINT NOT NULL PRIMARY KEY,
            retained_source_row_number BIGINT NOT NULL,
            discarded_change_reason NVARCHAR(50) NOT NULL,
            discarded_basic_salary DECIMAL(18, 2) NOT NULL,
            reason NVARCHAR(255) NOT NULL
        );
    END;


    -- 9. Rebuild outputs inside the transaction.
    DELETE FROM staging.history_resolution_log;
    DELETE FROM staging.employment_history;

    INSERT INTO staging.employment_history (
        emp_id,
        effective_from,
        effective_to,
        dept_id,
        designation,
        grade,
        basic_salary,
        change_reason,
        source_effective_to,
        _source_file,
        _source_row_number
    )
    SELECT
        emp_id,
        effective_from,
        effective_to,
        dept_id,
        designation,
        grade,
        basic_salary,
        change_reason,
        source_effective_to,
        _source_file,
        _source_row_number
    FROM #final_history;

    INSERT INTO staging.history_resolution_log (
        emp_id,
        effective_from,
        discarded_source_row_number,
        retained_source_row_number,
        discarded_change_reason,
        discarded_basic_salary,
        reason
    )
    SELECT
        emp_id,
        effective_from,
        _source_row_number,
        retained_source_row_number,
        change_reason,
        basic_salary,
        'Agreed assumption: same-day Salary Revision supersedes Hire'
    FROM #ranked_history
    WHERE version_rank > 1;


    -- 10. Account for every original history record.
    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.employment_history);

    DECLARE @retained_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.employment_history);

    DECLARE @resolved_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.history_resolution_log);

    IF @raw_count <> @retained_count + @resolved_count
        THROW 50016, 'Employment history reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @raw_count AS raw_records,
        @retained_count AS retained_history_records,
        @resolved_count AS logged_exclusions,
        'PASS' AS reconciliation;

    SELECT
        emp_id,
        effective_from,
        effective_to,
        dept_id,
        basic_salary,
        change_reason
    FROM staging.employment_history
    WHERE emp_id = 'E11259';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;