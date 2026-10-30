
WITH reporting_months AS (
    SELECT
        date_key AS month_date_key,
        calendar_date AS month_start,
        month_end,
        DATEADD(DAY, -1, calendar_date) AS opening_date

    FROM warehouse.dim_date

    WHERE calendar_date = month_start
      AND calendar_date BETWEEN '20260401' AND '20260901'
),
opening_headcount AS (
    SELECT
        month.month_date_key,
        employee.department_key,
        COUNT_BIG(*) AS headcount

    FROM reporting_months AS month

    INNER JOIN warehouse.dim_employee AS employee
        ON month.opening_date >= employee.valid_from
       AND (
           employee.valid_to IS NULL
           OR month.opening_date <= employee.valid_to
       )

    WHERE employee.hire_date <= month.opening_date
      AND (
          employee.separation_date IS NULL
          OR employee.separation_date > month.opening_date
      )

    GROUP BY
        month.month_date_key,
        employee.department_key
),
closing_headcount AS (
    SELECT
        month_date_key,
        department_key,
        COUNT_BIG(*) AS headcount

    FROM warehouse.fact_employee_month_snapshot

    WHERE is_month_end_headcount = 1

    GROUP BY month_date_key, department_key
),
separations AS (
    SELECT
        snapshot.month_date_key,
        snapshot.department_key,
        COUNT_BIG(*) AS separation_count

    FROM warehouse.fact_employee_month_snapshot AS snapshot

    INNER JOIN reporting_months AS month
        ON snapshot.month_date_key = month.month_date_key

    INNER JOIN warehouse.dim_employee AS employee
        ON snapshot.employee_key = employee.employee_key

    WHERE employee.separation_date
          BETWEEN month.month_start AND month.month_end

    GROUP BY
        snapshot.month_date_key,
        snapshot.department_key
),
department_months AS (
    SELECT
        month.month_start,
        department.plant,
        department.dept_id,
        department.dept_name,

        COALESCE(opening.headcount, 0) AS opening_headcount,
        COALESCE(closing.headcount, 0) AS closing_headcount,
        COALESCE(separation.separation_count, 0) AS separations

    FROM reporting_months AS month

    CROSS JOIN warehouse.dim_department AS department

    LEFT JOIN opening_headcount AS opening
        ON month.month_date_key = opening.month_date_key
       AND department.department_key = opening.department_key

    LEFT JOIN closing_headcount AS closing
        ON month.month_date_key = closing.month_date_key
       AND department.department_key = closing.department_key

    LEFT JOIN separations AS separation
        ON month.month_date_key = separation.month_date_key
       AND department.department_key = separation.department_key
),
averages AS (
    SELECT
        *,
        (opening_headcount + closing_headcount) / 2.0
            AS average_headcount
    FROM department_months
)
SELECT
    month_start,
    plant,
    dept_id,
    dept_name,
    opening_headcount,
    closing_headcount,

    CAST(
        average_headcount AS DECIMAL(12, 2)
    ) AS average_headcount,

    separations,

    CAST(
        100.0 * separations / NULLIF(average_headcount, 0)
        AS DECIMAL(12, 2)
    ) AS attrition_rate_percent

FROM averages

ORDER BY month_start, plant, dept_id;