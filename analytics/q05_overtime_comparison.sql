WITH computed_by_employee AS (
    SELECT
        attendance.employee_key,
        calendar.month_start,

        SUM(
            attendance.computed_overtime_hours
        ) AS computed_hours,

        SUM(CAST(
            CASE WHEN attendance.punch_count = 1 THEN 1 ELSE 0 END
            AS BIGINT
        )) AS incomplete_punch_days

    FROM warehouse.fact_attendance_daily AS attendance
    INNER JOIN warehouse.dim_date AS calendar
        ON attendance.date_key = calendar.date_key

    WHERE attendance.date_key BETWEEN 20260401 AND 20260930

    GROUP BY attendance.employee_key, calendar.month_start
),
computed AS (
    -- Combine SCD2 versions belonging to the same person/month.
    SELECT
        employee.emp_id,
        source.month_start,
        SUM(source.computed_hours) AS computed_hours,
        SUM(source.incomplete_punch_days) AS incomplete_punch_days

    FROM computed_by_employee AS source
    INNER JOIN warehouse.dim_employee AS employee
        ON source.employee_key = employee.employee_key

    GROUP BY employee.emp_id, source.month_start
),
approved AS (
    SELECT
        employee.emp_id,
        calendar.month_start,
        SUM(overtime.approved_hours) AS approved_hours

    FROM warehouse.fact_overtime_approved AS overtime
    INNER JOIN warehouse.dim_employee AS employee
        ON overtime.employee_key = employee.employee_key
    INNER JOIN warehouse.dim_date AS calendar
        ON overtime.date_key = calendar.date_key

    WHERE overtime.date_key BETWEEN 20260401 AND 20260930

    GROUP BY employee.emp_id, calendar.month_start
),
paid AS (
    SELECT
        employee.emp_id,
        calendar.month_start,
        SUM(payroll.units) AS paid_hours,
        SUM(payroll.amount) AS paid_overtime_amount

    FROM warehouse.fact_payroll_line AS payroll
    INNER JOIN warehouse.dim_employee AS employee
        ON payroll.employee_key = employee.employee_key
    INNER JOIN warehouse.dim_date AS calendar
        ON payroll.payroll_month_key = calendar.date_key

    WHERE payroll.component = 'OVERTIME'
      AND payroll.payroll_month_key BETWEEN 20260401 AND 20260901

    GROUP BY employee.emp_id, calendar.month_start
),
employee_month_totals AS (
    SELECT
        snapshot.month_date_key,
        snapshot.department_key,

        COALESCE(computed.computed_hours, 0) AS computed_hours,
        COALESCE(approved.approved_hours, 0) AS approved_hours,
        COALESCE(paid.paid_hours, 0) AS paid_hours,
        COALESCE(paid.paid_overtime_amount, 0) AS paid_overtime_amount,

        COALESCE(
            computed.incomplete_punch_days, 0
        ) AS incomplete_punch_days

    FROM warehouse.fact_employee_month_snapshot AS snapshot
    INNER JOIN warehouse.dim_date AS calendar
        ON snapshot.month_date_key = calendar.date_key

    LEFT JOIN computed
        ON snapshot.emp_id = computed.emp_id
       AND calendar.month_start = computed.month_start

    LEFT JOIN approved
        ON snapshot.emp_id = approved.emp_id
       AND calendar.month_start = approved.month_start

    LEFT JOIN paid
        ON snapshot.emp_id = paid.emp_id
       AND calendar.month_start = paid.month_start

    WHERE snapshot.month_date_key BETWEEN 20260401 AND 20260901
),
department_totals AS (
    SELECT
        month_date_key,
        department_key,
        SUM(computed_hours) AS computed_observed_hours,
        SUM(approved_hours) AS approved_hours,
        SUM(paid_hours) AS paid_hours,
        SUM(paid_overtime_amount) AS paid_overtime_amount,
        SUM(incomplete_punch_days) AS incomplete_punch_days

    FROM employee_month_totals

    GROUP BY month_date_key, department_key
),
reporting_months AS (
    SELECT date_key, month_start
    FROM warehouse.dim_date
    WHERE calendar_date = month_start
      AND date_key BETWEEN 20260401 AND 20260901
)
SELECT
    month.month_start,
    department.plant,
    department.dept_id,
    department.dept_name,

    COALESCE(totals.computed_observed_hours, 0)
        AS computed_observed_hours,

    COALESCE(totals.approved_hours, 0) AS approved_hours,
    COALESCE(totals.paid_hours, 0) AS paid_hours,

    COALESCE(totals.paid_hours, 0)
        - COALESCE(totals.computed_observed_hours, 0)
        AS paid_minus_computed_hours,

    COALESCE(totals.paid_overtime_amount, 0)
        AS paid_overtime_amount,

    COALESCE(totals.incomplete_punch_days, 0)
        AS incomplete_punch_days

FROM reporting_months AS month
CROSS JOIN warehouse.dim_department AS department

LEFT JOIN department_totals AS totals
    ON month.date_key = totals.month_date_key
   AND department.department_key = totals.department_key

ORDER BY month.month_start, department.plant, department.dept_id;