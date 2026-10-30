-- Q10: Approved Annual leave days exceed full-year entitlement.
-- Reporting period: 1 April to 30 September 2026.
-- Leave fact contains approved, eligible leave days only.
-- Department is as of September month-end or last working day.

WITH annual_leave_by_employee AS (
    SELECT
        e.emp_id,
        SUM(
            CAST(l.leave_day_count AS BIGINT)
        ) AS approved_annual_leave_days,
        COUNT(DISTINCT l.request_id) AS approved_annual_requests,
        MIN(l.date_key) AS first_leave_date_key,
        MAX(l.date_key) AS last_leave_date_key

    FROM warehouse.fact_leave_day AS l

    INNER JOIN warehouse.dim_employee AS e
        ON e.employee_key = l.employee_key

    WHERE l.leave_type = 'Annual'
      AND l.date_key BETWEEN 20260401 AND 20260930

    GROUP BY e.emp_id
)
SELECT
    a.emp_id,
    e.full_name,
    dept.plant,
    dept.dept_id,
    dept.dept_name,
    s.attribution_date AS department_as_of_date,
    e.hire_date,
    e.separation_date,

    e.annual_leave_entitlement AS full_year_entitlement_days,
    a.approved_annual_leave_days,

    a.approved_annual_leave_days
        - e.annual_leave_entitlement AS excess_leave_days,

    CAST(
        100.0 * a.approved_annual_leave_days
        / NULLIF(e.annual_leave_entitlement, 0)
        AS DECIMAL(18, 2)
    ) AS entitlement_used_percent,

    a.approved_annual_requests,
    first_day.calendar_date AS first_annual_leave_date,
    last_day.calendar_date AS last_annual_leave_date

FROM annual_leave_by_employee AS a

INNER JOIN warehouse.fact_employee_month_snapshot AS s
    ON s.emp_id = a.emp_id
   AND s.month_date_key = 20260901

INNER JOIN warehouse.dim_employee AS e
    ON e.employee_key = s.employee_key

INNER JOIN warehouse.dim_department AS dept
    ON dept.department_key = s.department_key

INNER JOIN warehouse.dim_date AS first_day
    ON first_day.date_key = a.first_leave_date_key

INNER JOIN warehouse.dim_date AS last_day
    ON last_day.date_key = a.last_leave_date_key

WHERE a.approved_annual_leave_days > e.annual_leave_entitlement

ORDER BY
    excess_leave_days DESC,
    a.approved_annual_leave_days DESC,
    a.emp_id;