USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;

DECLARE @period_start DATE = '20260401';
DECLARE @period_end_exclusive DATE = '20261001';

DROP TABLE IF EXISTS #monthly_overtime;

-- Stop if required inputs are empty.
IF NOT EXISTS (SELECT 1 FROM staging.attendance_daily)
    THROW 50170, 'Attendance input is empty.', 1;

IF NOT EXISTS (SELECT 1 FROM staging.overtime_requests)
    THROW 50171, 'Overtime request input is empty.', 1;

IF NOT EXISTS (SELECT 1 FROM staging.payroll_lines)
    THROW 50172, 'Payroll input is empty.', 1;

IF NOT EXISTS (SELECT 1 FROM staging.employee_month_department)
    THROW 50173, 'Employee-month mapping is empty.', 1;


-- 1. Aggregate the three sources independently.
WITH computed AS (
    SELECT
        emp_id,
        DATEFROMPARTS(
            YEAR(work_date), MONTH(work_date), 1
        ) AS month_start,

        SUM(computed_overtime_hours) AS observed_overtime_hours,

        -- Count incomplete days even if leave has status priority.
        SUM(
            CASE WHEN punch_count = 1 THEN 1 ELSE 0 END
        ) AS incomplete_punch_days

    FROM staging.attendance_daily
    WHERE work_date >= @period_start
      AND work_date < @period_end_exclusive
    GROUP BY emp_id, YEAR(work_date), MONTH(work_date)
),
approved AS (
    SELECT
        emp_id,
        DATEFROMPARTS(
            YEAR(ot_date), MONTH(ot_date), 1
        ) AS month_start,

        SUM(approved_hours) AS approved_overtime_hours

    FROM staging.overtime_requests
    WHERE status = 'Approved'
      AND ot_date >= @period_start
      AND ot_date < @period_end_exclusive
    GROUP BY emp_id, YEAR(ot_date), MONTH(ot_date)
),
paid AS (
    SELECT
        emp_id,
        payroll_month AS month_start,
        SUM(units) AS paid_overtime_hours,
        SUM(amount) AS paid_overtime_amount

    FROM staging.payroll_lines
    WHERE component = 'OVERTIME'
      AND payroll_month >= @period_start
      AND payroll_month < @period_end_exclusive
    GROUP BY emp_id, payroll_month
)
SELECT
    m.emp_id,
    m.month_start,
    m.dept_id,

    -- This is the observed total, not an estimate for missing punches.
    CAST(
        COALESCE(c.observed_overtime_hours, 0)
        AS DECIMAL(18, 4)
    ) AS observed_overtime_hours,

    COALESCE(c.incomplete_punch_days, 0) AS incomplete_punch_days,

    CAST(
        COALESCE(a.approved_overtime_hours, 0)
        AS DECIMAL(18, 4)
    ) AS approved_overtime_hours,

    CAST(
        COALESCE(p.paid_overtime_hours, 0)
        AS DECIMAL(18, 4)
    ) AS paid_overtime_hours,

    CAST(
        COALESCE(p.paid_overtime_amount, 0)
        AS DECIMAL(18, 2)
    ) AS paid_overtime_amount

INTO #monthly_overtime

FROM staging.employee_month_department AS m

LEFT JOIN computed AS c
    ON m.emp_id = c.emp_id
   AND m.month_start = c.month_start

LEFT JOIN approved AS a
    ON m.emp_id = a.emp_id
   AND m.month_start = a.month_start

LEFT JOIN paid AS p
    ON m.emp_id = p.emp_id
   AND m.month_start = p.month_start

WHERE m.month_start >= @period_start
  AND m.month_start < @period_end_exclusive;

CREATE UNIQUE CLUSTERED INDEX IX_monthly_overtime
    ON #monthly_overtime (emp_id, month_start);


-- 2. Verify no overtime totals were lost or multiplied.
IF (
    SELECT COALESCE(SUM(observed_overtime_hours), 0)
    FROM #monthly_overtime
) <> (
    SELECT COALESCE(SUM(computed_overtime_hours), 0)
    FROM staging.attendance_daily
    WHERE work_date >= @period_start
      AND work_date < @period_end_exclusive
)
    THROW 50174, 'Computed overtime reconciliation failed.', 1;

IF (
    SELECT COALESCE(SUM(approved_overtime_hours), 0)
    FROM #monthly_overtime
) <> (
    SELECT COALESCE(SUM(approved_hours), 0)
    FROM staging.overtime_requests
    WHERE status = 'Approved'
      AND ot_date >= @period_start
      AND ot_date < @period_end_exclusive
)
    THROW 50175, 'Approved overtime reconciliation failed.', 1;

IF (
    SELECT COALESCE(SUM(paid_overtime_hours), 0)
    FROM #monthly_overtime
) <> (
    SELECT COALESCE(SUM(units), 0)
    FROM staging.payroll_lines
    WHERE component = 'OVERTIME'
      AND payroll_month >= @period_start
      AND payroll_month < @period_end_exclusive
)
    THROW 50176, 'Paid overtime hours reconciliation failed.', 1;

IF (
    SELECT COALESCE(SUM(paid_overtime_amount), 0)
    FROM #monthly_overtime
) <> (
    SELECT COALESCE(SUM(amount), 0)
    FROM staging.payroll_lines
    WHERE component = 'OVERTIME'
      AND payroll_month >= @period_start
      AND payroll_month < @period_end_exclusive
)
    THROW 50177, 'Paid overtime amount reconciliation failed.', 1;


-- Result A: Successful aggregation checks.
SELECT
    COUNT_BIG(*) AS employee_months,
    'PASS' AS overtime_total_reconciliation
FROM #monthly_overtime;


-- Result B: Company-wide monthly comparison.
SELECT
    month_start,
    SUM(observed_overtime_hours) AS computed_observed_hours,
    SUM(approved_overtime_hours) AS approved_hours,
    SUM(paid_overtime_hours) AS paid_hours,
    SUM(paid_overtime_amount) AS paid_overtime_amount,
    SUM(incomplete_punch_days) AS incomplete_punch_days

FROM #monthly_overtime
GROUP BY month_start
ORDER BY month_start;


-- Result C: Department/month comparison.
WITH department_totals AS (
    SELECT
        month_start,
        dept_id,
        SUM(observed_overtime_hours) AS computed_observed_hours,
        SUM(approved_overtime_hours) AS approved_hours,
        SUM(paid_overtime_hours) AS paid_hours,
        SUM(incomplete_punch_days) AS incomplete_punch_days

    FROM #monthly_overtime
    GROUP BY month_start, dept_id
)
SELECT
    t.month_start,
    d.plant,
    d.dept_id,
    d.dept_name,
    t.computed_observed_hours,
    t.approved_hours,
    t.paid_hours,
    t.paid_hours - t.computed_observed_hours
        AS paid_minus_computed_hours,

    CAST(
        100.0 *
        (
            CAST(t.paid_hours AS DECIMAL(18, 4))
            - CAST(t.computed_observed_hours AS DECIMAL(18, 4))
        )
        / NULLIF(
            CAST(t.computed_observed_hours AS DECIMAL(18, 4)),
            0
        )
        AS DECIMAL(12, 2)
    ) AS paid_above_computed_percent,

    t.incomplete_punch_days

FROM department_totals AS t
INNER JOIN staging.departments AS d
    ON t.dept_id = d.dept_id

ORDER BY t.month_start, d.plant, d.dept_id;