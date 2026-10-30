
WITH reporting_months AS (
    SELECT
        date_key AS month_date_key,
        calendar_date AS month_start
    FROM warehouse.dim_date
    WHERE calendar_date = month_start
      AND calendar_date BETWEEN '20260401' AND '20260901'
),
department_headcount AS (
    SELECT
        month_date_key,
        department_key,
        COUNT_BIG(*) AS headcount
    FROM warehouse.fact_employee_month_snapshot
    WHERE is_month_end_headcount = 1
    GROUP BY month_date_key, department_key
)
SELECT
    month.month_start,
    department.plant,
    department.dept_id,
    department.dept_name,
    COALESCE(headcount.headcount, 0) AS month_end_headcount

FROM reporting_months AS month
CROSS JOIN warehouse.dim_department AS department

LEFT JOIN department_headcount AS headcount
    ON month.month_date_key = headcount.month_date_key
   AND department.department_key = headcount.department_key

ORDER BY
    month.month_start,
    department.plant,
    department.dept_id;