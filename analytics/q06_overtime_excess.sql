WITH attendance_by_version_month AS (
    SELECT
        employee_key,

        -- Convert YYYYMMDD into the month's YYYYMM01 key.
        (date_key / 100) * 100 + 1 AS month_date_key,

        SUM(computed_overtime_hours) AS computed_hours,

        SUM(CAST(
            CASE WHEN punch_count = 1 THEN 1 ELSE 0 END
            AS BIGINT
        )) AS incomplete_punch_days

    FROM warehouse.fact_attendance_daily

    WHERE date_key BETWEEN 20260401 AND 20260930

    GROUP BY
        employee_key,
        (date_key / 100) * 100 + 1
),
computed_by_department AS (
    SELECT
        attendance.month_date_key,
        snapshot.department_key,

        CAST(
            COALESCE(SUM(attendance.computed_hours), 0)
            AS DECIMAL(18, 4)
        ) AS computed_observed_hours,

        SUM(attendance.incomplete_punch_days)
            AS incomplete_punch_days

    FROM attendance_by_version_month AS attendance

    INNER JOIN warehouse.dim_employee AS employee
        ON attendance.employee_key = employee.employee_key

    INNER JOIN warehouse.fact_employee_month_snapshot AS snapshot
        ON employee.emp_id = snapshot.emp_id
       AND attendance.month_date_key = snapshot.month_date_key

    GROUP BY
        attendance.month_date_key,
        snapshot.department_key
),
paid_by_department AS (
    -- Payroll already uses the required monthly department.
    SELECT
        payroll_month_key AS month_date_key,
        department_key,

        CAST(
            SUM(units) AS DECIMAL(18, 4)
        ) AS paid_hours,

        SUM(amount) AS paid_overtime_amount

    FROM warehouse.fact_payroll_line

    WHERE component = 'OVERTIME'
      AND payroll_month_key BETWEEN 20260401 AND 20260901

    GROUP BY payroll_month_key, department_key
),
comparison AS (
    SELECT
        COALESCE(
            computed.month_date_key,
            paid.month_date_key
        ) AS month_date_key,

        COALESCE(
            computed.department_key,
            paid.department_key
        ) AS department_key,

        COALESCE(computed.computed_observed_hours, 0)
            AS computed_observed_hours,

        COALESCE(paid.paid_hours, 0) AS paid_hours,

        COALESCE(paid.paid_overtime_amount, 0)
            AS paid_overtime_amount,

        COALESCE(computed.incomplete_punch_days, 0)
            AS incomplete_punch_days

    FROM computed_by_department AS computed

    FULL OUTER JOIN paid_by_department AS paid
        ON computed.month_date_key = paid.month_date_key
       AND computed.department_key = paid.department_key
)
SELECT
    calendar.month_start,
    department.plant,
    department.dept_id,
    department.dept_name,
    comparison.computed_observed_hours,
    comparison.paid_hours,

    comparison.paid_hours
        - comparison.computed_observed_hours
        AS excess_paid_hours,

    CAST(
        100.0 *
        (
            comparison.paid_hours
            - comparison.computed_observed_hours
        )
        / NULLIF(comparison.computed_observed_hours, 0)
        AS DECIMAL(12, 2)
    ) AS paid_above_computed_percent,

    comparison.paid_overtime_amount,
    comparison.incomplete_punch_days,

    CASE
        WHEN comparison.computed_observed_hours = 0
            THEN 'Paid OT with zero observed OT'
        ELSE 'Paid OT exceeds observed OT by more than 15%'
    END AS review_reason

FROM comparison

INNER JOIN warehouse.dim_date AS calendar
    ON comparison.month_date_key = calendar.date_key

INNER JOIN warehouse.dim_department AS department
    ON comparison.department_key = department.department_key

WHERE comparison.paid_hours >
      comparison.computed_observed_hours * 1.15

ORDER BY
    calendar.month_start,
    excess_paid_hours DESC,
    department.dept_id;