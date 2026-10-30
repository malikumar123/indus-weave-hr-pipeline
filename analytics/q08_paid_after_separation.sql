-- Q08: Positive payroll earnings in months after separation.
-- Actual payment dates are unavailable.
-- These cases require review; final settlements or arrears may explain them.

WITH payroll_by_employee_month AS (
    SELECT
        e.emp_id,
        p.payroll_month_key AS month_date_key,

        SUM(
            CASE WHEN p.component_type = 'EARNING'
                 THEN p.amount ELSE 0 END
        ) AS gross_earnings,

        SUM(
            CASE WHEN p.component_type = 'DEDUCTION'
                 THEN p.amount ELSE 0 END
        ) AS deductions,

        SUM(
            CASE WHEN p.component = 'OVERTIME'
                      AND p.component_type = 'EARNING'
                 THEN p.amount ELSE 0 END
        ) AS overtime_amount,

        COUNT_BIG(*) AS payroll_line_count

    FROM warehouse.fact_payroll_line AS p
    INNER JOIN warehouse.dim_employee AS e
        ON e.employee_key = p.employee_key

    WHERE p.payroll_month_key BETWEEN 20260401 AND 20260901

    GROUP BY
        e.emp_id,
        p.payroll_month_key

    HAVING SUM(
        CASE WHEN p.component_type = 'EARNING'
             THEN p.amount ELSE 0 END
    ) > 0
)
SELECT
    d.month_start,
    p.emp_id,
    e.full_name,
    dept.plant,
    dept.dept_id,
    dept.dept_name,
    e.separation_date,

    DATEDIFF(
        MONTH,
        e.separation_date,
        d.month_start
    ) AS months_after_separation,

    CAST(p.gross_earnings AS DECIMAL(18, 2)) AS gross_earnings,
    CAST(p.deductions AS DECIMAL(18, 2)) AS deductions,

    CAST(
        p.gross_earnings - p.deductions
        AS DECIMAL(18, 2)
    ) AS net_payroll_amount,

    CAST(p.overtime_amount AS DECIMAL(18, 2)) AS overtime_amount,
    p.payroll_line_count,

    'Positive earnings in a month after separation month'
        AS review_reason

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

WHERE e.separation_date IS NOT NULL
  AND d.month_start > EOMONTH(e.separation_date)

ORDER BY
    d.month_start,
    dept.plant,
    dept.dept_id,
    p.emp_id;