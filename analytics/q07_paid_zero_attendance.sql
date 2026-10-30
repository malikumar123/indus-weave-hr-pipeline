-- Q07: Employees paid in a month with zero recorded punches.
-- Payroll month identifies the payment period; actual payment dates
-- are not available in the source.
-- Department follows the monthly payroll attribution.

WITH payroll_by_employee_month AS (
    SELECT
        e.emp_id,
        p.payroll_month_key AS month_date_key,
        SUM(p.amount) AS gross_earnings
    FROM warehouse.fact_payroll_line AS p
    INNER JOIN warehouse.dim_employee AS e
        ON e.employee_key = p.employee_key
    WHERE p.component_type = 'EARNING'
      AND p.payroll_month_key BETWEEN 20260401 AND 20260901
    GROUP BY
        e.emp_id,
        p.payroll_month_key
    HAVING SUM(p.amount) > 0
),
attendance_by_version_month AS (
    SELECT
        a.employee_key,
        (a.date_key / 100) * 100 + 1 AS month_date_key,
        COUNT_BIG(*) AS attendance_calendar_days,
        SUM(a.punch_count) AS recorded_punches,
        SUM(
            CAST(
                CASE WHEN a.punch_count > 0 THEN 1 ELSE 0 END
                AS BIGINT
            )
        ) AS days_with_punches,
        SUM(
            CAST(
                CASE WHEN a.attendance_status = 'On Leave'
                     THEN 1 ELSE 0 END
                AS BIGINT
            )
        ) AS approved_leave_days,
        SUM(
            CAST(
                CASE WHEN a.attendance_status = 'Absent'
                     THEN 1 ELSE 0 END
                AS BIGINT
            )
        ) AS absent_days
    FROM warehouse.fact_attendance_daily AS a
    WHERE a.date_key BETWEEN 20260401 AND 20260930
    GROUP BY
        a.employee_key,
        (a.date_key / 100) * 100 + 1
),
attendance_by_employee_month AS (
    SELECT
        e.emp_id,
        a.month_date_key,
        SUM(a.attendance_calendar_days) AS attendance_calendar_days,
        SUM(a.recorded_punches) AS recorded_punches,
        SUM(a.days_with_punches) AS days_with_punches,
        SUM(a.approved_leave_days) AS approved_leave_days,
        SUM(a.absent_days) AS absent_days
    FROM attendance_by_version_month AS a
    INNER JOIN warehouse.dim_employee AS e
        ON e.employee_key = a.employee_key
    GROUP BY
        e.emp_id,
        a.month_date_key
)
SELECT
    d.month_start,
    p.emp_id,
    e.full_name,
    dept.plant,
    dept.dept_id,
    dept.dept_name,
    e.hire_date,
    e.separation_date,
    CAST(p.gross_earnings AS DECIMAL(18, 2)) AS gross_earnings,
    COALESCE(a.attendance_calendar_days, 0) AS attendance_calendar_days,
    COALESCE(a.recorded_punches, 0) AS recorded_punches,
    COALESCE(a.days_with_punches, 0) AS days_with_punches,
    COALESCE(a.approved_leave_days, 0) AS approved_leave_days,
    COALESCE(a.absent_days, 0) AS absent_days,
    CASE
        WHEN a.emp_id IS NULL
            THEN 'Paid; no attendance rows for this month'
        ELSE 'Paid; attendance rows exist but no punches recorded'
    END AS review_reason
FROM payroll_by_employee_month AS p
INNER JOIN warehouse.fact_employee_month_snapshot AS s
    ON s.emp_id = p.emp_id
   AND s.month_date_key = p.month_date_key
INNER JOIN warehouse.dim_employee AS e
    ON e.employee_key = s.employee_key
INNER JOIN warehouse.dim_department AS dept
    ON dept.department_key = s.department_key
INNER JOIN warehouse.dim_date AS d
    ON d.date_key = p.month_date_key
LEFT JOIN attendance_by_employee_month AS a
    ON a.emp_id = p.emp_id
   AND a.month_date_key = p.month_date_key
WHERE COALESCE(a.recorded_punches, 0) = 0
ORDER BY
    d.month_start,
    dept.plant,
    dept.dept_id,
    p.emp_id;