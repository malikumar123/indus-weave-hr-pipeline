-- Q09: Gross payroll cost per month-end employee by department.
-- Monthly department attribution comes from the warehouse.
-- Deductions do not reduce gross payroll cost.
-- April has no prior reporting month for comparison.

WITH reporting_months AS (
    SELECT
        date_key AS month_date_key,
        month_start
    FROM warehouse.dim_date
    WHERE calendar_date = month_start
      AND date_key BETWEEN 20260401 AND 20260901
),
payroll_by_department AS (
    SELECT
        payroll_month_key AS month_date_key,
        department_key,
        SUM(amount) AS gross_payroll_cost
    FROM warehouse.fact_payroll_line
    WHERE component_type = 'EARNING'
      AND payroll_month_key BETWEEN 20260401 AND 20260901
    GROUP BY
        payroll_month_key,
        department_key
),
headcount_by_department AS (
    SELECT
        month_date_key,
        department_key,
        SUM(
            CAST(is_month_end_headcount AS BIGINT)
        ) AS month_end_headcount
    FROM warehouse.fact_employee_month_snapshot
    WHERE month_date_key BETWEEN 20260401 AND 20260901
    GROUP BY
        month_date_key,
        department_key
),
department_months AS (
    SELECT
        m.month_start,
        dept.department_key,
        dept.plant,
        dept.dept_id,
        dept.dept_name,

        COALESCE(h.month_end_headcount, 0) AS month_end_headcount,

        CAST(
            COALESCE(p.gross_payroll_cost, 0)
            AS DECIMAL(18, 2)
        ) AS gross_payroll_cost,

        CAST(
            COALESCE(p.gross_payroll_cost, 0)
            / NULLIF(
                CAST(h.month_end_headcount AS DECIMAL(18, 4)),
                0
            )
            AS DECIMAL(18, 4)
        ) AS payroll_cost_per_employee

    FROM reporting_months AS m
    CROSS JOIN warehouse.dim_department AS dept

    LEFT JOIN payroll_by_department AS p
        ON p.month_date_key = m.month_date_key
       AND p.department_key = dept.department_key

    LEFT JOIN headcount_by_department AS h
        ON h.month_date_key = m.month_date_key
       AND h.department_key = dept.department_key
),
with_previous_month AS (
    SELECT
        *,
        LAG(payroll_cost_per_employee) OVER (
            PARTITION BY department_key
            ORDER BY month_start
        ) AS previous_month_cost_per_employee
    FROM department_months
)
SELECT
    month_start,
    plant,
    dept_id,
    dept_name,
    month_end_headcount,
    gross_payroll_cost,

    CAST(
        payroll_cost_per_employee AS DECIMAL(18, 2)
    ) AS payroll_cost_per_employee,

    CAST(
        previous_month_cost_per_employee AS DECIMAL(18, 2)
    ) AS previous_month_cost_per_employee,

    CAST(
        payroll_cost_per_employee
        - previous_month_cost_per_employee
        AS DECIMAL(18, 2)
    ) AS mom_cost_per_employee_change,

    CAST(
        100.0
        * (
            payroll_cost_per_employee
            - previous_month_cost_per_employee
        )
        / NULLIF(previous_month_cost_per_employee, 0)
        AS DECIMAL(18, 2)
    ) AS mom_cost_per_employee_change_percent

FROM with_previous_month
ORDER BY
    month_start,
    plant,
    dept_id;