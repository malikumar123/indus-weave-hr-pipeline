USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @period_start DATE = '20260401';
    DECLARE @period_end DATE = '20260930';

    DROP TABLE IF EXISTS #schedule;

    -- 1. Generate reporting dates, then employed employee-days.
    WITH reporting_dates AS (
        SELECT @period_start AS work_date

        UNION ALL

        SELECT DATEADD(DAY, 1, work_date)
        FROM reporting_dates
        WHERE work_date < @period_end
    ),
    employee_days AS (
        SELECT
            e.emp_id,
            d.work_date
        FROM staging.employees AS e
        CROSS JOIN reporting_dates AS d
        WHERE d.work_date >= e.hire_date
          AND (
              e.separation_date IS NULL
              OR d.work_date <= e.separation_date
          )
    ),
    schedule_context AS (
        SELECT
            ed.emp_id,
            ed.work_date,
            h.dept_id,
            d.plant,
            r.shift_code,
            s.start_time,
            s.end_time,
            s.crosses_midnight,
            s.grace_minutes

        FROM employee_days AS ed

        LEFT JOIN staging.employment_history AS h
            ON ed.emp_id = h.emp_id
           AND ed.work_date >= h.effective_from
           AND (
               h.effective_to IS NULL
               OR ed.work_date <= h.effective_to
           )

        LEFT JOIN staging.departments AS d
            ON h.dept_id = d.dept_id

        LEFT JOIN staging.shift_roster_resolved AS r
            ON ed.emp_id = r.emp_id
           AND r.week_start = DATEADD(
                DAY,
                -(DATEDIFF(DAY, '19000101', ed.work_date) % 7),
                ed.work_date
           )

        LEFT JOIN staging.shifts AS s
            ON r.shift_code = s.shift_code
    )
    SELECT
        c.emp_id,
        c.work_date,
        c.dept_id,
        c.plant,
        c.shift_code,
        c.grace_minutes,

        DATEADD(
            SECOND,
            DATEDIFF(
                SECOND,
                CAST('00:00:00' AS TIME),
                c.start_time
            ),
            CAST(c.work_date AS DATETIME2)
        ) AS scheduled_start,

        DATEADD(
            DAY,
            CAST(c.crosses_midnight AS INT),
            DATEADD(
                SECOND,
                DATEDIFF(
                    SECOND,
                    CAST('00:00:00' AS TIME),
                    c.end_time
                ),
                CAST(c.work_date AS DATETIME2)
            )
        ) AS scheduled_end,

        CAST(
            CASE
                WHEN DATEDIFF(DAY, '19000101', c.work_date) % 7 = 6
                THEN 1 ELSE 0
            END AS BIT
        ) AS is_weekly_off,

        CAST(
            CASE WHEN EXISTS (
                SELECT 1
                FROM staging.holidays AS holiday
                WHERE holiday.holiday_date = c.work_date
                  AND (
                      holiday.scope = 'ALL'
                      OR holiday.scope =
                          CASE c.plant
                              WHEN 'Head Office' THEN 'HO'
                              WHEN 'Korangi Plant' THEN 'KOR'
                              WHEN 'SITE Plant' THEN 'SITE'
                              WHEN 'Faisalabad Plant' THEN 'FSD'
                          END
                  )
            ) THEN 1 ELSE 0 END AS BIT
        ) AS is_holiday,

        CAST(
            CASE WHEN EXISTS (
                SELECT 1
                FROM staging.leave_days AS l
                WHERE l.emp_id = c.emp_id
                  AND l.leave_date = c.work_date
            ) THEN 1 ELSE 0 END AS BIT
        ) AS has_approved_leave

    INTO #schedule
    FROM schedule_context AS c
    OPTION (MAXRECURSION 366);


    -- 2. Stop if required history or roster information is missing.
    IF EXISTS (
        SELECT 1
        FROM #schedule
        WHERE dept_id IS NULL
           OR plant IS NULL
           OR shift_code IS NULL
           OR grace_minutes IS NULL
           OR scheduled_start IS NULL
           OR scheduled_end IS NULL
    )
    BEGIN
        SELECT TOP (20) *
        FROM #schedule
        WHERE dept_id IS NULL
           OR plant IS NULL
           OR shift_code IS NULL
           OR grace_minutes IS NULL
           OR scheduled_start IS NULL
           OR scheduled_end IS NULL;

        THROW 50110, 'Incomplete employee schedule context.', 1;
    END;

    IF EXISTS (
        SELECT emp_id, work_date
        FROM #schedule
        GROUP BY emp_id, work_date
        HAVING COUNT(*) > 1
    )
        THROW 50111, 'Multiple schedule rows for an employee-day.', 1;

    IF EXISTS (
        SELECT 1
        FROM #schedule
        WHERE scheduled_end <= scheduled_start
           OR scheduled_end > DATEADD(HOUR, 16, scheduled_start)
    )
        THROW 50112, 'Invalid scheduled shift duration.', 1;


    -- 3. Independently calculate expected employed days.
    DECLARE @expected_days BIGINT;

    SELECT @expected_days = COALESCE(
        SUM(
            CAST(
                DATEDIFF(
                    DAY,
                    CASE
                        WHEN hire_date > @period_start
                        THEN hire_date
                        ELSE @period_start
                    END,
                    CASE
                        WHEN separation_date < @period_end
                        THEN separation_date
                        ELSE @period_end
                    END
                ) + 1 AS BIGINT
            )
        ),
        0
    )
    FROM staging.employees
    WHERE hire_date <= @period_end
      AND (
          separation_date IS NULL
          OR separation_date >= @period_start
      );

    IF @expected_days <> (SELECT COUNT_BIG(*) FROM #schedule)
        THROW 50113, 'Employee-day coverage check failed.', 1;


    -- 4. Create and populate the persistent schedule.
    IF OBJECT_ID(N'staging.employee_schedule', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.employee_schedule (
            emp_id NVARCHAR(50) NOT NULL,
            work_date DATE NOT NULL,
            dept_id NVARCHAR(50) NOT NULL,
            plant NVARCHAR(100) NOT NULL,
            shift_code NVARCHAR(20) NOT NULL,
            grace_minutes INT NOT NULL,
            scheduled_start DATETIME2(6) NOT NULL,
            scheduled_end DATETIME2(6) NOT NULL,
            is_weekly_off BIT NOT NULL,
            is_holiday BIT NOT NULL,
            has_approved_leave BIT NOT NULL,

            PRIMARY KEY (emp_id, work_date),

            CHECK (scheduled_end > scheduled_start)
        );
    END;

    DELETE FROM staging.employee_schedule;

    INSERT INTO staging.employee_schedule (
        emp_id,
        work_date,
        dept_id,
        plant,
        shift_code,
        grace_minutes,
        scheduled_start,
        scheduled_end,
        is_weekly_off,
        is_holiday,
        has_approved_leave
    )
    SELECT
        emp_id,
        work_date,
        dept_id,
        plant,
        shift_code,
        grace_minutes,
        scheduled_start,
        scheduled_end,
        is_weekly_off,
        is_holiday,
        has_approved_leave
    FROM #schedule;

    DECLARE @actual_days BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.employee_schedule);

    IF @actual_days <> @expected_days
        THROW 50114, 'Stored schedule count mismatch.', 1;

    COMMIT TRANSACTION;

    -- Result A: Complete employee-day coverage.
    SELECT
        @expected_days AS expected_employee_days,
        @actual_days AS scheduled_employee_days,
        'PASS' AS coverage_check;

    -- Result B: Schedule distribution.
    SELECT
        shift_code,
        COUNT_BIG(*) AS employee_days
    FROM staging.employee_schedule
    GROUP BY shift_code
    ORDER BY shift_code;

    -- Result C: Confirm night shifts end the next day.
    SELECT TOP (5)
        emp_id,
        work_date,
        shift_code,
        scheduled_start,
        scheduled_end
    FROM staging.employee_schedule
    WHERE shift_code = 'NIGHT'
    ORDER BY emp_id, work_date;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;