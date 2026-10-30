USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @period_start DATE = '20260401';
    DECLARE @period_end DATE = '20260930';

    DROP TABLE IF EXISTS #expanded_leave;
    DROP TABLE IF EXISTS #classified_days;

    -- 1. Expand each approved request into calendar dates.
    WITH approved_requests AS (
        SELECT
            l.request_id,
            l.emp_id,
            l.leave_type,
            l.from_date,
            l.to_date
        FROM staging.leave_requests AS l
        INNER JOIN staging.leave_request_status AS s
            ON l.request_id = s.request_id
        WHERE s.is_approved = 1
    ),
    request_dates AS (
        SELECT
            request_id,
            emp_id,
            leave_type,
            from_date AS leave_date,
            to_date
        FROM approved_requests

        UNION ALL

        SELECT
            request_id,
            emp_id,
            leave_type,
            DATEADD(DAY, 1, leave_date),
            to_date
        FROM request_dates
        WHERE leave_date < to_date
    )
    SELECT
        request_id,
        emp_id,
        leave_type,
        leave_date
    INTO #expanded_leave
    FROM request_dates
    OPTION (MAXRECURSION 0);


    -- 2. Every employed, in-period date needs a history record.
    IF EXISTS (
        SELECT 1
        FROM #expanded_leave AS l
        INNER JOIN staging.employees AS e
            ON l.emp_id = e.emp_id
        WHERE l.leave_date BETWEEN @period_start AND @period_end
          AND l.leave_date >= e.hire_date
          AND (
              e.separation_date IS NULL
              OR l.leave_date <= e.separation_date
          )
          AND NOT EXISTS (
              SELECT 1
              FROM staging.employment_history AS h
              WHERE h.emp_id = l.emp_id
                AND l.leave_date >= h.effective_from
                AND (
                    h.effective_to IS NULL
                    OR l.leave_date <= h.effective_to
                )
          )
    )
        THROW 50100, 'Leave date has no matching employment history.', 1;


    -- Validate plant names before using holiday scope mappings.
    IF EXISTS (
        SELECT 1
        FROM staging.departments
        WHERE plant NOT IN (
            'Head Office',
            'Korangi Plant',
            'SITE Plant',
            'Faisalabad Plant'
        )
    )
        THROW 50101, 'Unknown plant: holiday scope mapping required.', 1;


    -- 3. Find the department/plant effective on each leave date.
    -- Exclude nonworking dates using EXISTS to avoid multiplying rows.
    SELECT
        l.request_id,
        l.emp_id,
        l.leave_type,
        l.leave_date,
        h.dept_id,

        CASE
            WHEN l.leave_date < @period_start
              OR l.leave_date > @period_end
                THEN 'Outside reporting period'

            WHEN l.leave_date < e.hire_date
              OR l.leave_date > e.separation_date
                THEN 'Outside employment dates'

            WHEN DATEDIFF(DAY, '19000101', l.leave_date) % 7 = 6
                THEN 'Sunday'

            WHEN EXISTS (
                SELECT 1
                FROM staging.holidays AS holiday
                WHERE holiday.holiday_date = l.leave_date
                  AND (
                      holiday.scope = 'ALL'
                      OR holiday.scope =
                          CASE d.plant
                              WHEN 'Head Office' THEN 'HO'
                              WHEN 'Korangi Plant' THEN 'KOR'
                              WHEN 'SITE Plant' THEN 'SITE'
                              WHEN 'Faisalabad Plant' THEN 'FSD'
                          END
                  )
            )
                THEN 'Plant or public holiday'

            ELSE NULL
        END AS exclusion_reason

    INTO #classified_days
    FROM #expanded_leave AS l
    INNER JOIN staging.employees AS e
        ON l.emp_id = e.emp_id
    LEFT JOIN staging.employment_history AS h
        ON l.emp_id = h.emp_id
       AND l.leave_date >= h.effective_from
       AND (
           h.effective_to IS NULL
           OR l.leave_date <= h.effective_to
       )
    LEFT JOIN staging.departments AS d
        ON h.dept_id = d.dept_id;


    -- 4. Create accepted-day and excluded-day tables.
    IF OBJECT_ID(N'staging.leave_days', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.leave_days (
            request_id NVARCHAR(100) NOT NULL,
            leave_date DATE NOT NULL,
            emp_id NVARCHAR(50) NOT NULL,
            leave_type NVARCHAR(50) NOT NULL,
            dept_id NVARCHAR(50) NOT NULL,

            PRIMARY KEY (request_id, leave_date)
        );

        CREATE INDEX IX_leave_days_employee_date
            ON staging.leave_days (emp_id, leave_date);
    END;

    IF OBJECT_ID(N'staging.leave_day_exclusions', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.leave_day_exclusions (
            request_id NVARCHAR(100) NOT NULL,
            leave_date DATE NOT NULL,
            exclusion_reason NVARCHAR(100) NOT NULL,

            PRIMARY KEY (request_id, leave_date)
        );
    END;

    DELETE FROM staging.leave_days;
    DELETE FROM staging.leave_day_exclusions;

    INSERT INTO staging.leave_days (
        request_id, leave_date, emp_id, leave_type, dept_id
    )
    SELECT
        request_id, leave_date, emp_id, leave_type, dept_id
    FROM #classified_days
    WHERE exclusion_reason IS NULL;

    INSERT INTO staging.leave_day_exclusions (
        request_id, leave_date, exclusion_reason
    )
    SELECT
        request_id, leave_date, exclusion_reason
    FROM #classified_days
    WHERE exclusion_reason IS NOT NULL;


    -- 5. Account for every expanded calendar day.
    DECLARE @expanded_count BIGINT =
        (SELECT COUNT_BIG(*) FROM #expanded_leave);

    DECLARE @accepted_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.leave_days);

    DECLARE @excluded_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.leave_day_exclusions);

    IF @expanded_count <> @accepted_count + @excluded_count
        THROW 50102, 'Leave-day reconciliation failed.', 1;

    COMMIT TRANSACTION;

    -- Result A: Reconciliation at request/day level.
    SELECT
        @expanded_count AS expanded_calendar_days,
        @accepted_count AS accepted_leave_days,
        @excluded_count AS excluded_calendar_days,
        'PASS' AS reconciliation;

    -- Result B: Reasons for excluded dates.
    SELECT
        exclusion_reason,
        COUNT_BIG(*) AS excluded_days
    FROM staging.leave_day_exclusions
    GROUP BY exclusion_reason
    ORDER BY exclusion_reason;

    -- Result C: Check overlapping approved requests.
    SELECT
        emp_id,
        leave_date,
        COUNT_BIG(*) AS overlapping_requests
    FROM staging.leave_days
    GROUP BY emp_id, leave_date
    HAVING COUNT_BIG(*) > 1
    ORDER BY emp_id, leave_date;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

-- Stop if request classifications are missing or incomplete.
IF EXISTS (
    SELECT 1
    FROM staging.leave_requests AS l
    LEFT JOIN staging.leave_request_status AS s
        ON l.request_id = s.request_id
    WHERE s.request_id IS NULL
)
    THROW 50103,
        'Leave classifications are incomplete. Run script 14 first.',
        1;