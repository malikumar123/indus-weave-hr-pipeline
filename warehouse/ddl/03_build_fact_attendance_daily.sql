USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #attendance_fact;

    IF NOT EXISTS (SELECT 1 FROM staging.attendance_daily)
        THROW 50200, 'Staging attendance is empty.', 1;


    -- 1. Resolve dimension keys, preserving unmatched rows for checks.
    SELECT
        a.emp_id,
        a.work_date,

        e.employee_key,
        e.department_key AS employee_department_key,
        department.department_key,
        shift.shift_key,
        calendar.date_key,

        a.scheduled_start,
        a.scheduled_end,
        a.is_weekly_off,
        a.is_holiday,
        a.has_approved_leave,
        a.punch_count,
        a.first_punch_time,
        a.last_punch_time,
        a.attendance_status,
        a.worked_hours,
        a.late_minutes,
        a.early_departure_minutes,
        a.computed_overtime_hours

    INTO #attendance_fact

    FROM staging.attendance_daily AS a

    LEFT JOIN warehouse.dim_employee AS e
        ON a.emp_id = e.emp_id
       AND a.work_date >= e.valid_from
       AND (
           e.valid_to IS NULL
           OR a.work_date <= e.valid_to
       )

    LEFT JOIN warehouse.dim_department AS department
        ON a.dept_id = department.dept_id

    LEFT JOIN warehouse.dim_shift AS shift
        ON a.shift_code = shift.shift_code

    LEFT JOIN warehouse.dim_date AS calendar
        ON a.work_date = calendar.calendar_date;


    -- 2. Every fact must have valid dimension keys.
    IF EXISTS (
        SELECT 1
        FROM #attendance_fact
        WHERE employee_key IS NULL
           OR department_key IS NULL
           OR shift_key IS NULL
           OR date_key IS NULL
    )
    BEGIN
        SELECT TOP (20)
            emp_id,
            work_date,
            employee_key,
            department_key,
            shift_key,
            date_key
        FROM #attendance_fact
        WHERE employee_key IS NULL
           OR department_key IS NULL
           OR shift_key IS NULL
           OR date_key IS NULL;

        THROW 50201, 'Attendance dimension lookup failed.', 1;
    END;

    IF EXISTS (
        SELECT emp_id, work_date
        FROM #attendance_fact
        GROUP BY emp_id, work_date
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50202, 'Multiple employee versions matched an attendance day.', 1;

    -- Daily department must agree with the effective employee version.
    IF EXISTS (
        SELECT 1
        FROM #attendance_fact
        WHERE department_key <> employee_department_key
    )
        THROW 50203, 'Attendance and employee-history departments disagree.', 1;


    -- 3. Create the fact table with enforced foreign keys.
    IF OBJECT_ID(N'warehouse.fact_attendance_daily', N'U') IS NULL
    BEGIN
        CREATE TABLE warehouse.fact_attendance_daily (
            employee_key INT NOT NULL,
            date_key INT NOT NULL,
            department_key INT NOT NULL,
            shift_key INT NOT NULL,

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

            PRIMARY KEY (employee_key, date_key),

            FOREIGN KEY (employee_key)
                REFERENCES warehouse.dim_employee(employee_key),

            FOREIGN KEY (date_key)
                REFERENCES warehouse.dim_date(date_key),

            FOREIGN KEY (department_key)
                REFERENCES warehouse.dim_department(department_key),

            FOREIGN KEY (shift_key)
                REFERENCES warehouse.dim_shift(shift_key),

            CHECK (
                attendance_status IN (
                    'Present', 'Absent', 'On Leave',
                    'Holiday', 'Weekly Off', 'Missing Punch'
                )
            ),

            CHECK (scheduled_end > scheduled_start),
            CHECK (punch_count >= 0),
            CHECK (worked_hours IS NULL OR worked_hours BETWEEN 0 AND 16),
            CHECK (late_minutes >= 0),
            CHECK (early_departure_minutes >= 0),

            CHECK (
                computed_overtime_hours IS NULL
                OR computed_overtime_hours >= 0
            )
        );

        CREATE INDEX IX_attendance_date_department
            ON warehouse.fact_attendance_daily (
                date_key, department_key
            );
    END;


    -- 4. Rebuild facts inside the transaction.
    DELETE FROM warehouse.fact_attendance_daily;

    INSERT INTO warehouse.fact_attendance_daily (
        employee_key,
        date_key,
        department_key,
        shift_key,
        scheduled_start,
        scheduled_end,
        is_weekly_off,
        is_holiday,
        has_approved_leave,
        punch_count,
        first_punch_time,
        last_punch_time,
        attendance_status,
        worked_hours,
        late_minutes,
        early_departure_minutes,
        computed_overtime_hours
    )
    SELECT
        employee_key,
        date_key,
        department_key,
        shift_key,
        scheduled_start,
        scheduled_end,
        is_weekly_off,
        is_holiday,
        has_approved_leave,
        punch_count,
        first_punch_time,
        last_punch_time,
        attendance_status,
        worked_hours,
        late_minutes,
        early_departure_minutes,
        computed_overtime_hours
    FROM #attendance_fact;


    -- 5. Reconcile counts, measures, and unknown OT values.
    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.attendance_daily);

    DECLARE @warehouse_count BIGINT =
        (SELECT COUNT_BIG(*) FROM warehouse.fact_attendance_daily);

    IF @staging_count <> @warehouse_count
        THROW 50204, 'Attendance fact row reconciliation failed.', 1;

    IF (
        SELECT COALESCE(SUM(punch_count), 0)
        FROM staging.attendance_daily
    ) <> (
        SELECT COALESCE(SUM(punch_count), 0)
        FROM warehouse.fact_attendance_daily
    )
        THROW 50205, 'Attendance fact punch reconciliation failed.', 1;

    IF (
        SELECT COALESCE(SUM(computed_overtime_hours), 0)
        FROM staging.attendance_daily
    ) <> (
        SELECT COALESCE(SUM(computed_overtime_hours), 0)
        FROM warehouse.fact_attendance_daily
    )
        THROW 50206, 'Attendance fact overtime reconciliation failed.', 1;

    IF (
        SELECT COUNT_BIG(*)
        FROM staging.attendance_daily
        WHERE computed_overtime_hours IS NULL
    ) <> (
        SELECT COUNT_BIG(*)
        FROM warehouse.fact_attendance_daily
        WHERE computed_overtime_hours IS NULL
    )
        THROW 50207, 'Unknown overtime values were not preserved.', 1;

    COMMIT TRANSACTION;

    SELECT
        @staging_count AS staging_attendance_rows,
        @warehouse_count AS warehouse_attendance_rows,
        'PASS' AS reconciliation;

    SELECT
        attendance_status,
        COUNT_BIG(*) AS employee_days
    FROM warehouse.fact_attendance_daily
    GROUP BY attendance_status
    ORDER BY attendance_status;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;