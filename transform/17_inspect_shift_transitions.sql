USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;

DROP TABLE IF EXISTS #shift_transitions;

SELECT
    emp_id,
    work_date,
    shift_code,
    scheduled_start,
    scheduled_end,

    LEAD(shift_code) OVER (
        PARTITION BY emp_id
        ORDER BY work_date
    ) AS next_shift_code,

    LEAD(scheduled_start) OVER (
        PARTITION BY emp_id
        ORDER BY work_date
    ) AS next_scheduled_start

INTO #shift_transitions
FROM staging.employee_schedule;


-- Result A: Check the shortest interval between consecutive shifts.
SELECT
    shift_code,
    next_shift_code,
    COUNT_BIG(*) AS transition_count,

    MIN(
        DATEDIFF(MINUTE, scheduled_end, next_scheduled_start)
    ) AS minimum_gap_minutes,

    MAX(
        DATEDIFF(MINUTE, scheduled_end, next_scheduled_start)
    ) AS maximum_gap_minutes

FROM #shift_transitions
WHERE next_scheduled_start IS NOT NULL
GROUP BY shift_code, next_shift_code
ORDER BY shift_code, next_shift_code;


-- Result B: Examples where shifts touch or overlap.
SELECT TOP (20)
    emp_id,
    work_date,
    shift_code,
    scheduled_start,
    scheduled_end,
    next_shift_code,
    next_scheduled_start

FROM #shift_transitions
WHERE next_scheduled_start <= scheduled_end
ORDER BY emp_id, work_date;


-- Result C: Verify punches extending beyond September.
SELECT
    CAST(corrected_punch_time AS DATE) AS punch_date,
    COUNT_BIG(*) AS retained_punches
FROM staging.biometric_punches
WHERE corrected_punch_time >= '20260930'
GROUP BY CAST(corrected_punch_time AS DATE)
ORDER BY punch_date;