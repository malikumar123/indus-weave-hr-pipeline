USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;

DROP TABLE IF EXISTS #assignment_candidates;
DROP TABLE IF EXISTS #best_candidates;
DROP TABLE IF EXISTS #assignment_summary;

-- These are diagnostic search limits, not attendance business rules.
-- Anything outside them remains visible as unmatched.
DECLARE @early_minutes INT = 120;
DECLARE @after_end_hours INT = 8;


-- 1. Consider nearby shift dates for each punch.
-- Looking at the previous date preserves night-shift checkouts.
-- Looking at the next date supports an early punch before midnight.
SELECT
    p._source_row_number,
    p.punch_id,
    p.emp_id,
    p.corrected_punch_time,
    s.work_date,
    s.shift_code,
    s.scheduled_start,
    s.scheduled_end,

    -- Distance from the scheduled working interval.
    -- A punch inside the interval has distance zero.
    CASE
        WHEN p.corrected_punch_time < s.scheduled_start
            THEN DATEDIFF_BIG(
                MICROSECOND,
                p.corrected_punch_time,
                s.scheduled_start
            )

        WHEN p.corrected_punch_time > s.scheduled_end
            THEN DATEDIFF_BIG(
                MICROSECOND,
                s.scheduled_end,
                p.corrected_punch_time
            )

        ELSE CAST(0 AS BIGINT)
    END AS distance_microseconds

INTO #assignment_candidates

FROM staging.biometric_punches AS p

CROSS APPLY (
    VALUES
        (DATEADD(DAY, -1, CAST(p.corrected_punch_time AS DATE))),
        (CAST(p.corrected_punch_time AS DATE)),
        (DATEADD(DAY, 1, CAST(p.corrected_punch_time AS DATE)))
) AS possible_dates(work_date)

INNER JOIN staging.employee_schedule AS s
    ON p.emp_id = s.emp_id
   AND possible_dates.work_date = s.work_date

WHERE p.corrected_punch_time >=
      DATEADD(MINUTE, -@early_minutes, s.scheduled_start)

  AND p.corrected_punch_time <=
      DATEADD(HOUR, @after_end_hours, s.scheduled_end);


-- Supports grouping and finding the nearest candidates.
CREATE CLUSTERED INDEX IX_assignment_candidates
    ON #assignment_candidates (
        _source_row_number,
        distance_microseconds,
        work_date
    );


-- 2. Retain ALL equally close candidates.
-- Do not silently break ties by choosing the earlier date.
WITH ranked_candidates AS (
    SELECT
        *,

        DENSE_RANK() OVER (
            PARTITION BY _source_row_number
            ORDER BY distance_microseconds
        ) AS candidate_rank

    FROM #assignment_candidates
)
SELECT
    _source_row_number,
    punch_id,
    emp_id,
    corrected_punch_time,
    work_date,
    shift_code,
    scheduled_start,
    scheduled_end,
    distance_microseconds

INTO #best_candidates
FROM ranked_candidates
WHERE candidate_rank = 1;

CREATE CLUSTERED INDEX IX_best_candidates
    ON #best_candidates (_source_row_number, work_date);


-- 3. Classify every retained punch.
WITH candidate_counts AS (
    SELECT
        _source_row_number,
        COUNT_BIG(*) AS best_candidate_count
    FROM #best_candidates
    GROUP BY _source_row_number
)
SELECT
    p._source_row_number,

    CASE
        WHEN c.best_candidate_count IS NULL
            THEN 'Unmatched'
        WHEN c.best_candidate_count = 1
            THEN 'One nearest candidate'
        ELSE 'Ambiguous nearest candidates'
    END AS assignment_review

INTO #assignment_summary
FROM staging.biometric_punches AS p
LEFT JOIN candidate_counts AS c
    ON p._source_row_number = c._source_row_number;


-- Result A: Every retained punch must appear exactly once.
SELECT
    assignment_review,
    COUNT_BIG(*) AS punch_count
FROM #assignment_summary
GROUP BY assignment_review
ORDER BY assignment_review;


-- Result B: Show both shift options for ambiguous punches.
SELECT TOP (30)
    b.emp_id,
    b.punch_id,
    b.corrected_punch_time,
    b.work_date AS candidate_work_date,
    b.shift_code,
    b.scheduled_start,
    b.scheduled_end

FROM #best_candidates AS b
INNER JOIN #assignment_summary AS a
    ON b._source_row_number = a._source_row_number

WHERE a.assignment_review = 'Ambiguous nearest candidates'
ORDER BY b.emp_id, b.corrected_punch_time, b.work_date;


-- Result C: Show punches outside the diagnostic search windows.
SELECT TOP (20)
    p.emp_id,
    p.punch_id,
    p.corrected_punch_time

FROM staging.biometric_punches AS p
INNER JOIN #assignment_summary AS a
    ON p._source_row_number = a._source_row_number

WHERE a.assignment_review = 'Unmatched'
ORDER BY p.emp_id, p.corrected_punch_time;