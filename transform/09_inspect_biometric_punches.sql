USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;

DROP TABLE IF EXISTS #punches;
DROP TABLE IF EXISTS #arrival_offsets;

-- 1. Parse timestamps and map users using BOTH device keys.
SELECT
    p.punch_id,
    LTRIM(RTRIM(p.device_id)) AS device_id,
    LTRIM(RTRIM(p.device_user_id)) AS device_user_id,

    TRY_CONVERT(
        DATETIME2(6),
        NULLIF(LTRIM(RTRIM(p.punch_time)), ''),
        126
    ) AS punch_time,

    m.emp_id,
    p._source_row_number

INTO #punches
FROM raw.biometric_punches AS p
LEFT JOIN staging.device_mapping AS m
    ON LTRIM(RTRIM(p.device_id)) = m.device_id
   AND LTRIM(RTRIM(p.device_user_id)) = m.device_user_id;


-- Result A: Account for all punches.
SELECT
    COUNT_BIG(*) AS total_punches,

    SUM(CAST(
        CASE
            WHEN punch_time IS NOT NULL AND emp_id IS NOT NULL
            THEN 1 ELSE 0
        END AS BIGINT
    )) AS mapped_valid_punches,

    SUM(CAST(
        CASE
            WHEN punch_time IS NOT NULL AND emp_id IS NULL
            THEN 1 ELSE 0
        END AS BIGINT
    )) AS unmapped_valid_punches,

    SUM(CAST(
        CASE WHEN punch_time IS NULL THEN 1 ELSE 0 END
        AS BIGINT
    )) AS invalid_timestamp_punches

FROM #punches;


-- Result B: Inspect a sample of unmapped users.
SELECT TOP (10)
    device_id,
    device_user_id,
    COUNT_BIG(*) AS punch_count
FROM #punches
WHERE emp_id IS NULL
GROUP BY device_id, device_user_id
ORDER BY punch_count DESC, device_id, device_user_id;


-- 2. Examine arrivals for DAY and GEN shifts.
-- These shifts provide a simpler clock diagnostic than night shifts.
WITH punch_dates AS (
    SELECT
        emp_id,
        device_id,
        punch_time,
        CAST(punch_time AS DATE) AS punch_date
    FROM #punches
    WHERE emp_id IS NOT NULL
      AND punch_time IS NOT NULL
),
scheduled_punches AS (
    SELECT
        p.emp_id,
        p.device_id,
        p.punch_date,
        p.punch_time,
        r.shift_code,

        DATEADD(
            SECOND,
            DATEDIFF(
                SECOND,
                CAST('00:00:00' AS TIME),
                s.start_time
            ),
            CAST(p.punch_date AS DATETIME2)
        ) AS scheduled_start

    FROM punch_dates AS p
    INNER JOIN staging.shift_roster_resolved AS r
        ON p.emp_id = r.emp_id
       AND r.week_start = DATEADD(
            DAY,
            -(DATEDIFF(DAY, '19000101', p.punch_date) % 7),
            p.punch_date
       )
    INNER JOIN staging.shifts AS s
        ON r.shift_code = s.shift_code

    WHERE r.shift_code IN ('DAY', 'GEN')
      AND p.punch_date BETWEEN '20260401' AND '20260930'
),
arrival_candidates AS (
    SELECT *
    FROM scheduled_punches
    WHERE punch_time >= DATEADD(MINUTE, -120, scheduled_start)
      AND punch_time <= DATEADD(MINUTE, 180, scheduled_start)
)
SELECT
    emp_id,
    device_id,
    punch_date,
    shift_code,

    DATEDIFF(
        SECOND,
        scheduled_start,
        MIN(punch_time)
    ) / 60.0 AS arrival_offset_minutes

INTO #arrival_offsets
FROM arrival_candidates
GROUP BY
    emp_id,
    device_id,
    punch_date,
    shift_code,
    scheduled_start;


-- Result C: Compare typical arrival offsets across devices.
WITH offset_statistics AS (
    SELECT
        device_id,
        shift_code,
        arrival_offset_minutes,

        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY arrival_offset_minutes
        ) OVER (
            PARTITION BY device_id, shift_code
        ) AS median_offset

    FROM #arrival_offsets
)
SELECT
    device_id,
    shift_code,
    COUNT_BIG(*) AS sampled_employee_days,
    CAST(AVG(arrival_offset_minutes) AS DECIMAL(10, 2))
        AS average_offset_minutes,
    CAST(MAX(median_offset) AS DECIMAL(10, 2))
        AS median_offset_minutes
FROM offset_statistics
GROUP BY device_id, shift_code
ORDER BY shift_code, device_id;

-- Result D: Compare arrival offsets by month.
WITH monthly_offsets AS (
    SELECT
        device_id,
        shift_code,

        DATEFROMPARTS(
            YEAR(punch_date),
            MONTH(punch_date),
            1
        ) AS month_start,

        arrival_offset_minutes
    FROM #arrival_offsets
),
monthly_statistics AS (
    SELECT
        *,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY arrival_offset_minutes
        ) OVER (
            PARTITION BY device_id, shift_code, month_start
        ) AS median_offset
    FROM monthly_offsets
)
SELECT
    device_id,
    shift_code,
    month_start,
    COUNT_BIG(*) AS sampled_employee_days,

    CAST(
        AVG(arrival_offset_minutes) AS DECIMAL(10, 2)
    ) AS average_offset_minutes,

    CAST(
        MAX(median_offset) AS DECIMAL(10, 2)
    ) AS median_offset_minutes

FROM monthly_statistics
WHERE shift_code = 'DAY'
GROUP BY
    device_id,
    shift_code,
    month_start
ORDER BY
    month_start,
    device_id;