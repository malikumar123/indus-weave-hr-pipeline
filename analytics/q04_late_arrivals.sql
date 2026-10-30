WITH late_by_version AS (
    SELECT
        attendance.employee_key,
        COUNT_BIG(*) AS late_arrival_days,
        SUM(attendance.late_minutes) AS total_late_minutes

    FROM warehouse.fact_attendance_daily AS attendance

    WHERE attendance.date_key BETWEEN 20260401 AND 20260930
      AND attendance.attendance_status = 'Present'
      AND attendance.is_weekly_off = 0
      AND attendance.is_holiday = 0
      AND attendance.late_minutes > 0

    GROUP BY attendance.employee_key
),
late_arrivals AS (
    SELECT
        employee.emp_id,
        SUM(late.late_arrival_days) AS late_arrival_days,
        SUM(late.total_late_minutes) AS total_late_minutes

    FROM late_by_version AS late
    INNER JOIN warehouse.dim_employee AS employee
        ON late.employee_key = employee.employee_key

    GROUP BY employee.emp_id
),
ranked_employees AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            ORDER BY late_arrival_days DESC, emp_id
        ) AS late_rank
    FROM late_arrivals
)
SELECT
    ranked.late_rank,
    ranked.emp_id,
    employee.full_name,
    department.plant,
    department.dept_id,
    department.dept_name,
    snapshot.attribution_date AS department_as_of_date,
    ranked.late_arrival_days,

    CAST(
        ranked.total_late_minutes AS DECIMAL(12, 2)
    ) AS total_late_minutes

FROM ranked_employees AS ranked

INNER JOIN warehouse.fact_employee_month_snapshot AS snapshot
    ON ranked.emp_id = snapshot.emp_id

INNER JOIN warehouse.dim_date AS snapshot_month
    ON snapshot.month_date_key = snapshot_month.date_key
   AND snapshot_month.calendar_date = '20260901'

INNER JOIN warehouse.dim_employee AS employee
    ON snapshot.employee_key = employee.employee_key

INNER JOIN warehouse.dim_department AS department
    ON snapshot.department_key = department.department_key

WHERE ranked.late_rank <= 10

ORDER BY ranked.late_rank;