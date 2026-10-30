USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;

-- Rebuild the diagnostic input in this connection.
DROP TABLE IF EXISTS #punches;

SELECT
    LTRIM(RTRIM(p.device_id)) AS device_id,

    TRY_CONVERT(
        DATETIME2(6),
        NULLIF(LTRIM(RTRIM(p.punch_time)), ''),
        126
    ) AS punch_time,

    m.emp_id

INTO #punches
FROM raw.biometric_punches AS p

LEFT JOIN staging.device_mapping AS m
    ON LTRIM(RTRIM(p.device_id)) = m.device_id
   AND LTRIM(RTRIM(p.device_user_id)) = m.device_user_id;

PRINT 'Diagnostic input prepared.';

DROP TABLE IF EXISTS #clock_punches;
DROP TABLE IF EXISTS #clock_days;
DROP TABLE IF EXISTS #clock_starts;
DROP TABLE IF EXISTS #clock_arrivals;

-- Validate before converting text to a bounded type.
IF EXISTS (
    SELECT 1
    FROM #punches
    WHERE LEN(device_id) > 100
)
    THROW 50051, 'Device ID exceeds the diagnostic column length.', 1;


-- 1. Keep only the columns and reporting dates needed.
SELECT
    emp_id,
    CAST(device_id AS NVARCHAR(100)) AS device_id,
    CAST(punch_time AS DATE) AS punch_date,
    punch_time

INTO #clock_punches
FROM #punches
WHERE emp_id IS NOT NULL
  AND punch_time >= '20260401'
  AND punch_time < '20261001';

-- Index supports finding the first punch near each shift start.
CREATE CLUSTERED INDEX IX_clock_punches
    ON #clock_punches (emp_id, punch_date, punch_time);

PRINT 'Step 1 complete: diagnostic punches indexed.';


-- 2. One row per employee/calendar date with punches.
SELECT DISTINCT
    emp_id,
    punch_date

INTO #clock_days
FROM #clock_punches;

CREATE UNIQUE CLUSTERED INDEX IX_clock_days
    ON #clock_days (emp_id, punch_date);


-- 3. Find scheduled DAY shift starts.
SELECT
    d.emp_id,
    d.punch_date,

    DATEADD(
        SECOND,
        DATEDIFF(
            SECOND,
            CAST('00:00:00' AS TIME),
            s.start_time
        ),
        CAST(d.punch_date AS DATETIME2)
    ) AS scheduled_start

INTO #clock_starts
FROM #clock_days AS d
INNER JOIN staging.shift_roster_resolved AS r
    ON d.emp_id = r.emp_id
   AND r.week_start = DATEADD(
        DAY,
        -(DATEDIFF(DAY, '19000101', d.punch_date) % 7),
        d.punch_date
   )
INNER JOIN staging.shifts AS s
    ON r.shift_code = s.shift_code
WHERE r.shift_code = 'DAY';

PRINT 'Step 2 complete: scheduled DAY starts prepared.';


-- 4. Use indexed lookups to find the first nearby punch.
SELECT
    s.emp_id,
    s.punch_date,
    arrival.device_id,

    DATEDIFF(
        SECOND,
        s.scheduled_start,
        arrival.punch_time
    ) / 60.0 AS arrival_offset_minutes

INTO #clock_arrivals
FROM #clock_starts AS s

CROSS APPLY (
    SELECT TOP (1)
        p.device_id,
        p.punch_time
    FROM #clock_punches AS p
    WHERE p.emp_id = s.emp_id
      AND p.punch_date = s.punch_date
      AND p.punch_time >= DATEADD(
          MINUTE, -120, s.scheduled_start
      )
      AND p.punch_time <= DATEADD(
          MINUTE, 180, s.scheduled_start
      )
    ORDER BY p.punch_time, p.device_id
) AS arrival;

PRINT 'Step 3 complete: arrival offsets calculated.';


-- 5. Small monthly summary without windowed median calculations.
SELECT
    device_id,

    DATEFROMPARTS(
        YEAR(punch_date),
        MONTH(punch_date),
        1
    ) AS month_start,

    COUNT_BIG(*) AS sampled_employee_days,

    CAST(
        AVG(arrival_offset_minutes) AS DECIMAL(10, 2)
    ) AS average_offset_minutes

FROM #clock_arrivals
GROUP BY
    device_id,
    YEAR(punch_date),
    MONTH(punch_date)
ORDER BY
    month_start,
    device_id;

-- Inspect the suspected clock-change boundary.
SELECT
    device_id,
    punch_date,
    COUNT_BIG(*) AS sampled_employee_days,

    CAST(
        AVG(arrival_offset_minutes) AS DECIMAL(10, 2)
    ) AS average_offset_minutes

FROM #clock_arrivals
WHERE punch_date BETWEEN '20260625' AND '20260707'
GROUP BY
    device_id,
    punch_date
ORDER BY
    punch_date,
    device_id;