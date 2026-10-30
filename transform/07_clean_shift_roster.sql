USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @period_start DATE = '20260401';
    DECLARE @period_end DATE = '20260930';

    DROP TABLE IF EXISTS #roster;
    DROP TABLE IF EXISTS #resolved;

    -- 1. Clean the source assignments.
    SELECT
        NULLIF(LTRIM(RTRIM(emp_id)), '') AS emp_id,

        TRY_CONVERT(
            DATE,
            NULLIF(LTRIM(RTRIM(week_start)), ''),
            23
        ) AS week_start,

        UPPER(
            NULLIF(LTRIM(RTRIM(shift_code)), '')
        ) AS shift_code,

        _source_row_number

    INTO #roster
    FROM raw.shift_roster;

    -- Monday check uses a known Monday, independent of DATEFIRST.
    IF EXISTS (
        SELECT 1
        FROM #roster
        WHERE emp_id IS NULL
           OR week_start IS NULL
           OR shift_code IS NULL
           OR LEN(emp_id) > 50
           OR LEN(shift_code) > 20
           OR DATEDIFF(DAY, '19000101', week_start) % 7 <> 0
    )
        THROW 50030, 'Invalid roster values or non-Monday week start.', 1;

    IF EXISTS (
        SELECT emp_id, week_start
        FROM #roster
        GROUP BY emp_id, week_start
        HAVING COUNT(*) > 1
    )
        THROW 50031, 'Multiple roster assignments for one employee/week.', 1;

    IF EXISTS (
        SELECT 1
        FROM #roster AS r
        LEFT JOIN staging.employees AS e
            ON r.emp_id = e.emp_id
        LEFT JOIN staging.shifts AS s
            ON r.shift_code = s.shift_code
        WHERE e.emp_id IS NULL
           OR s.shift_code IS NULL
    )
        THROW 50032, 'Unknown employee or shift in roster.', 1;

    -- Set bounded types after validating source values.
    ALTER TABLE #roster
    ALTER COLUMN emp_id NVARCHAR(50) NOT NULL;

    ALTER TABLE #roster
    ALTER COLUMN week_start DATE NOT NULL;

    -- Support efficient lookup of the previous known assignment.
    CREATE UNIQUE CLUSTERED INDEX IX_temp_roster
        ON #roster (emp_id, week_start);

    -- 2. Generate Mondays covering the reporting period.
    DECLARE @first_monday DATE =
        DATEADD(
            DAY,
            -(DATEDIFF(DAY, '19000101', @period_start) % 7),
            @period_start
        );

    WITH weeks AS (
        SELECT @first_monday AS week_start

        UNION ALL

        SELECT DATEADD(DAY, 7, week_start)
        FROM weeks
        WHERE DATEADD(DAY, 7, week_start) <= @period_end
    ),
    employee_weeks AS (
        SELECT
            e.emp_id,
            w.week_start
        FROM staging.employees AS e
        CROSS JOIN weeks AS w
        WHERE e.hire_date <= @period_end
          AND (
              e.separation_date IS NULL
              OR e.separation_date >= @period_start
          )
          AND e.hire_date <= DATEADD(DAY, 6, w.week_start)
          AND (
              e.separation_date IS NULL
              OR e.separation_date >= w.week_start
          )
    )
    SELECT
        ew.emp_id,
        ew.week_start,
        previous_assignment.shift_code,
        previous_assignment.week_start AS assignment_source_week,

        CAST(
            CASE
                WHEN previous_assignment.week_start = ew.week_start
                THEN 0
                ELSE 1
            END AS BIT
        ) AS is_carried_forward,

        previous_assignment._source_row_number

    INTO #resolved
    FROM employee_weeks AS ew

    OUTER APPLY (
        SELECT TOP (1)
            r.shift_code,
            r.week_start,
            r._source_row_number
        FROM #roster AS r
        WHERE r.emp_id = ew.emp_id
          AND r.week_start <= ew.week_start
        ORDER BY r.week_start DESC
    ) AS previous_assignment

    OPTION (MAXRECURSION 100);

    -- Never invent a shift when no previous assignment exists.
    IF EXISTS (
        SELECT 1
        FROM #resolved
        WHERE shift_code IS NULL
    )
    BEGIN
        SELECT emp_id, week_start
        FROM #resolved
        WHERE shift_code IS NULL;

        THROW 50033, 'Cannot fill roster: no prior assignment exists.', 1;
    END;

    -- 3. Create output tables.
    IF OBJECT_ID(N'staging.shift_roster', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.shift_roster (
            emp_id NVARCHAR(50) NOT NULL,
            week_start DATE NOT NULL,
            shift_code NVARCHAR(20) NOT NULL,
            _source_row_number BIGINT NOT NULL,

            PRIMARY KEY (emp_id, week_start)
        );
    END;

    IF OBJECT_ID(N'staging.shift_roster_resolved', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.shift_roster_resolved (
            emp_id NVARCHAR(50) NOT NULL,
            week_start DATE NOT NULL,
            shift_code NVARCHAR(20) NOT NULL,
            assignment_source_week DATE NOT NULL,
            is_carried_forward BIT NOT NULL,
            _source_row_number BIGINT NOT NULL,

            PRIMARY KEY (emp_id, week_start),

            CHECK (assignment_source_week <= week_start)
        );
    END;

    -- 4. Rebuild both outputs.
    DELETE FROM staging.shift_roster_resolved;
    DELETE FROM staging.shift_roster;

    INSERT INTO staging.shift_roster (
        emp_id, week_start, shift_code, _source_row_number
    )
    SELECT
        emp_id, week_start, shift_code, _source_row_number
    FROM #roster;

    INSERT INTO staging.shift_roster_resolved (
        emp_id,
        week_start,
        shift_code,
        assignment_source_week,
        is_carried_forward,
        _source_row_number
    )
    SELECT
        emp_id,
        week_start,
        shift_code,
        assignment_source_week,
        is_carried_forward,
        _source_row_number
    FROM #resolved;

    -- 5. Reconcile the source-preserving staging table.
    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.shift_roster);

    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.shift_roster);

    IF @raw_count <> @staging_count
        THROW 50034, 'Roster reconciliation failed.', 1;

    DECLARE @expected_resolved BIGINT =
        (SELECT COUNT_BIG(*) FROM #resolved);

    DECLARE @actual_resolved BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.shift_roster_resolved);

    IF @expected_resolved <> @actual_resolved
        THROW 50035, 'Resolved roster count mismatch.', 1;

    COMMIT TRANSACTION;

    SELECT
        @raw_count AS raw_records,
        @staging_count AS staging_records,
        'PASS' AS reconciliation;

    SELECT
        COUNT_BIG(*) AS resolved_employee_weeks,
        SUM(
            CAST(is_carried_forward AS BIGINT)
        ) AS carried_forward_weeks
    FROM staging.shift_roster_resolved;

    SELECT TOP (10)
        emp_id,
        week_start,
        shift_code,
        assignment_source_week,
        is_carried_forward
    FROM staging.shift_roster_resolved
    WHERE is_carried_forward = 1
    ORDER BY emp_id, week_start;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;