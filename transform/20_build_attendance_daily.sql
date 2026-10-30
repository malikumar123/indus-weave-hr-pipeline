USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #daily_punches;
    DROP TABLE IF EXISTS #attendance;

    -- 1. Check prerequisites before rebuilding outputs.
    IF NOT EXISTS (SELECT 1 FROM staging.employee_schedule)
        THROW 50130, 'Employee schedule is empty. Run script 16.', 1;

    IF EXISTS (
        SELECT 1
        FROM staging.biometric_punches AS p
        LEFT JOIN staging.punch_shift_assignment AS a
            ON p._source_row_number = a._source_row_number
        WHERE a._source_row_number IS NULL
    )
        THROW 50131, 'Some retained punches have no shift assignment.', 1;

    IF EXISTS (
        SELECT 1
        FROM staging.punch_shift_assignment AS a
        LEFT JOIN staging.biometric_punches AS p
            ON a._source_row_number = p._source_row_number
           AND a.emp_id = p.emp_id
           AND a.punch_id = p.punch_id
        LEFT JOIN staging.employee_schedule AS s
            ON a.emp_id = s.emp_id
           AND a.work_date = s.work_date
        WHERE p._source_row_number IS NULL
           OR s.emp_id IS NULL
    )
        THROW 50132, 'Invalid or stale punch assignments found.', 1;


    -- 2. Pair first and last punches by assigned shift date.
    SELECT
        a.emp_id,
        a.work_date,
        COUNT_BIG(*) AS punch_count,
        MIN(p.corrected_punch_time) AS first_punch_time,
        MAX(p.corrected_punch_time) AS last_punch_time

    INTO #daily_punches

    FROM staging.punch_shift_assignment AS a
    INNER JOIN staging.biometric_punches AS p
        ON a._source_row_number = p._source_row_number

    GROUP BY a.emp_id, a.work_date;

    CREATE UNIQUE CLUSTERED INDEX IX_daily_punches
        ON #daily_punches (emp_id, work_date);


    -- 3. Start from the complete schedule so absent days survive.
    WITH daily_context AS (
        SELECT
            s.*,
            COALESCE(p.punch_count, 0) AS punch_count,
            p.first_punch_time,
            p.last_punch_time

        FROM staging.employee_schedule AS s
        LEFT JOIN #daily_punches AS p
            ON s.emp_id = p.emp_id
           AND s.work_date = p.work_date
    ),
    statuses AS (
        SELECT
            *,

            -- Apply the dictionary's exact priority order.
            CASE
                WHEN is_weekly_off = 1 AND punch_count = 0
                    THEN 'Weekly Off'
                WHEN is_holiday = 1 AND punch_count = 0
                    THEN 'Holiday'
                WHEN has_approved_leave = 1
                    THEN 'On Leave'
                WHEN punch_count >= 2
                    THEN 'Present'
                WHEN punch_count = 1
                    THEN 'Missing Punch'
                ELSE 'Absent'
            END AS attendance_status

        FROM daily_context
    ),
    durations AS (
        SELECT
            *,

            CASE
                WHEN punch_count >= 2
                THEN DATEDIFF_BIG(
                    MICROSECOND,
                    first_punch_time,
                    last_punch_time
                )
                WHEN punch_count = 0 THEN CAST(0 AS BIGINT)
                ELSE NULL
            END AS worked_microseconds,

            CASE
                WHEN punch_count < 2 THEN NULL

                -- All observed work on Sundays/holidays is OT.
                WHEN is_weekly_off = 1 OR is_holiday = 1
                THEN DATEDIFF_BIG(
                    MICROSECOND,
                    first_punch_time,
                    last_punch_time
                )

                -- Count only observed time after scheduled end.
                WHEN last_punch_time > scheduled_end
                THEN DATEDIFF_BIG(
                    MICROSECOND,
                    CASE
                        WHEN first_punch_time > scheduled_end
                        THEN first_punch_time
                        ELSE scheduled_end
                    END,
                    last_punch_time
                )

                ELSE CAST(0 AS BIGINT)
            END AS overtime_microseconds

        FROM statuses
    )
    SELECT
        emp_id,
        work_date,
        dept_id,
        plant,
        shift_code,
        scheduled_start,
        scheduled_end,
        is_weekly_off,
        is_holiday,
        has_approved_leave,
        punch_count,
        first_punch_time,
        last_punch_time,
        attendance_status,

        CAST(
            worked_microseconds / 3600000000.0
            AS DECIMAL(12, 4)
        ) AS worked_hours,

        -- More than 10 minutes late; measure the whole delay.
        CAST(
            CASE
                WHEN attendance_status = 'Present'
                 AND is_weekly_off = 0
                 AND is_holiday = 0
                 AND first_punch_time >
                     DATEADD(MINUTE, 10, scheduled_start)
                THEN DATEDIFF_BIG(
                    MICROSECOND,
                    scheduled_start,
                    first_punch_time
                ) / 60000000.0
                ELSE 0
            END AS DECIMAL(12, 4)
        ) AS late_minutes,

        -- More than 10 minutes early; measure the whole shortfall.
        CAST(
            CASE
                WHEN attendance_status = 'Present'
                 AND is_weekly_off = 0
                 AND is_holiday = 0
                 AND last_punch_time <
                     DATEADD(MINUTE, -10, scheduled_end)
                THEN DATEDIFF_BIG(
                    MICROSECOND,
                    last_punch_time,
                    scheduled_end
                ) / 60000000.0
                ELSE 0
            END AS DECIMAL(12, 4)
        ) AS early_departure_minutes,

        CAST(
            CASE
                WHEN punch_count = 0 THEN 0
                WHEN punch_count = 1 THEN NULL
                ELSE
                    -- Integer division rounds down to half-hours.
                    (overtime_microseconds / 1800000000) * 0.5
            END AS DECIMAL(12, 2)
        ) AS computed_overtime_hours

    INTO #attendance
    FROM durations;


    -- 4. Validate observed durations before publishing.
    IF EXISTS (
        SELECT 1
        FROM #attendance
        WHERE worked_hours < 0
           OR (
               punch_count >= 2
               AND last_punch_time >
                   DATEADD(HOUR, 16, first_punch_time)
           )
    )
    BEGIN
        SELECT TOP (20)
            emp_id,
            work_date,
            shift_code,
            punch_count,
            first_punch_time,
            last_punch_time,
            worked_hours
        FROM #attendance
        WHERE worked_hours < 0
           OR (
               punch_count >= 2
               AND last_punch_time >
                   DATEADD(HOUR, 16, first_punch_time)
           )
        ORDER BY worked_hours DESC;

        THROW 50133, 'Invalid worked duration. Review punch assignment.', 1;
    END;

    DECLARE @expected_days BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.employee_schedule);

    IF @expected_days <> (SELECT COUNT_BIG(*) FROM #attendance)
        THROW 50134, 'Attendance employee-day coverage failed.', 1;

    DECLARE @retained_punches BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.biometric_punches);

    IF @retained_punches <>
       (SELECT COALESCE(SUM(punch_count), 0) FROM #attendance)
        THROW 50135, 'Attendance punch reconciliation failed.', 1;


    -- 5. Create and populate the daily attendance table.
    IF OBJECT_ID(N'staging.attendance_daily', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.attendance_daily (
            emp_id NVARCHAR(50) NOT NULL,
            work_date DATE NOT NULL,
            dept_id NVARCHAR(50) NOT NULL,
            plant NVARCHAR(100) NOT NULL,
            shift_code NVARCHAR(20) NOT NULL,
            scheduled_start DATETIME2(6) NOT NULL,
            scheduled_end DATETIME2(6) NOT NULL,
            is_weekly_off BIT NOT NULL,
            is_holiday BIT NOT NULL,
            has_approved_leave BIT NOT NULL,
            punch_count BIGINT NOT NULL,
            first_punch_time DATETIME2(6) NULL,
            last_punch_time DATETIME2(6) NULL,
            attendance_status NVARCHAR(20) NOT NULL,
            worked_hours DECIMAL(12, 4) NULL,
            late_minutes DECIMAL(12, 4) NOT NULL,
            early_departure_minutes DECIMAL(12, 4) NOT NULL,
            computed_overtime_hours DECIMAL(12, 2) NULL,

            PRIMARY KEY (emp_id, work_date),

            CHECK (
                attendance_status IN (
                    'Present', 'Absent', 'On Leave',
                    'Holiday', 'Weekly Off', 'Missing Punch'
                )
            ),

            CHECK (punch_count >= 0),
            CHECK (worked_hours IS NULL OR worked_hours >= 0),
            CHECK (late_minutes >= 0),
            CHECK (early_departure_minutes >= 0),

            CHECK (
                computed_overtime_hours IS NULL
                OR computed_overtime_hours >= 0
            )
        );
    END;

    DELETE FROM staging.attendance_daily;

    INSERT INTO staging.attendance_daily (
        emp_id, work_date, dept_id, plant, shift_code,
        scheduled_start, scheduled_end,
        is_weekly_off, is_holiday, has_approved_leave,
        punch_count, first_punch_time, last_punch_time,
        attendance_status, worked_hours, late_minutes,
        early_departure_minutes, computed_overtime_hours
    )
    SELECT
        emp_id, work_date, dept_id, plant, shift_code,
        scheduled_start, scheduled_end,
        is_weekly_off, is_holiday, has_approved_leave,
        punch_count, first_punch_time, last_punch_time,
        attendance_status, worked_hours, late_minutes,
        early_departure_minutes, computed_overtime_hours
    FROM #attendance;

    DECLARE @actual_days BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.attendance_daily);

    IF @actual_days <> @expected_days
        THROW 50136, 'Stored attendance row count failed.', 1;

    COMMIT TRANSACTION;

    -- Result A: Employee-day and punch coverage.
    SELECT
        @expected_days AS expected_employee_days,
        @actual_days AS attendance_rows,
        @retained_punches AS accounted_punches,
        'PASS' AS reconciliation;

    -- Result B: Attendance status distribution.
    SELECT
        attendance_status,
        COUNT_BIG(*) AS employee_days
    FROM staging.attendance_daily
    GROUP BY attendance_status
    ORDER BY attendance_status;

    -- Result C: Examples of computed overtime.
    SELECT TOP (10)
        emp_id,
        work_date,
        shift_code,
        attendance_status,
        scheduled_end,
        first_punch_time,
        last_punch_time,
        worked_hours,
        computed_overtime_hours
    FROM staging.attendance_daily
    WHERE computed_overtime_hours > 0
    ORDER BY computed_overtime_hours DESC, emp_id, work_date;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;