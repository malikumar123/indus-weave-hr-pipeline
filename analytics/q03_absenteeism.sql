WITH eligible_days AS (
    SELECT
        calendar.month_start,
        department.plant,
        attendance.attendance_status,
        attendance.punch_count

    FROM warehouse.fact_attendance_daily AS attendance

    INNER JOIN warehouse.dim_date AS calendar
        ON attendance.date_key = calendar.date_key

    INNER JOIN warehouse.dim_department AS department
        ON attendance.department_key = department.department_key

    WHERE calendar.calendar_date
          BETWEEN '20260401' AND '20260930'

      AND attendance.is_weekly_off = 0
      AND attendance.is_holiday = 0
      AND attendance.has_approved_leave = 0
),
plant_month_totals AS (
    SELECT
        month_start,
        plant,
        COUNT_BIG(*) AS eligible_working_days,

        SUM(CAST(
            CASE
                WHEN attendance_status = 'Absent' THEN 1
                ELSE 0
            END AS BIGINT
        )) AS absent_days,

        SUM(CAST(
            CASE
                WHEN punch_count = 1 THEN 1
                ELSE 0
            END AS BIGINT
        )) AS missing_punch_days

    FROM eligible_days

    GROUP BY month_start, plant
)
SELECT
    month_start,
    plant,
    eligible_working_days,
    absent_days,
    missing_punch_days,

    CAST(
        100.0 * absent_days
        / NULLIF(eligible_working_days, 0)
        AS DECIMAL(12, 2)
    ) AS absenteeism_rate_percent

FROM plant_month_totals

ORDER BY month_start, plant;