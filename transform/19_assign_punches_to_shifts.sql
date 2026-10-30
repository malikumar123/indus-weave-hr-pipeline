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

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #counted_candidates;
    DROP TABLE IF EXISTS #resolved_assignments;

    -- 3. Count the equally close candidates for each punch.
    SELECT
        *,
        COUNT_BIG(*) OVER (
            PARTITION BY _source_row_number
        ) AS candidate_count

    INTO #counted_candidates
    FROM #best_candidates;

    CREATE INDEX IX_counted_candidates_employee_date
        ON #counted_candidates (emp_id, work_date)
        INCLUDE (
            candidate_count,
            corrected_punch_time,
            shift_code
        );
    CREATE UNIQUE CLUSTERED INDEX IX_counted_candidates_source_date
    ON #counted_candidates (_source_row_number, work_date);

    -- 4. Keep unique matches.
        -- 4A. Process straightforward matches separately.
    SELECT
        b._source_row_number,
        b.punch_id,
        b.emp_id,
        b.work_date,

        CAST(
            'Unique nearest scheduled interval'
            AS NVARCHAR(200)
        ) AS assignment_method

    INTO #resolved_assignments
    FROM #counted_candidates AS b
    WHERE b.candidate_count = 1;


    -- 4B. Materialize the small set of tied DAY candidates.
    DROP TABLE IF EXISTS #day_boundary_candidates;

    SELECT *
    INTO #day_boundary_candidates
    FROM #counted_candidates
    WHERE candidate_count = 2
      AND shift_code = 'DAY'
      AND corrected_punch_time = scheduled_start;


    -- Apply contextual checks only to those tied candidates.
    INSERT INTO #resolved_assignments (
        _source_row_number,
        punch_id,
        emp_id,
        work_date,
        assignment_method
    )
    SELECT
        b._source_row_number,
        b.punch_id,
        b.emp_id,
        b.work_date,
        'DAY boundary: daytime checkout evidence; no NIGHT evidence'

    FROM #day_boundary_candidates AS b

    WHERE EXISTS (
        SELECT 1
        FROM #counted_candidates AS night_candidate

        WHERE night_candidate._source_row_number =
              b._source_row_number

          AND night_candidate.shift_code = 'NIGHT'

          AND night_candidate.scheduled_end =
              b.scheduled_start

          AND NOT EXISTS (
              SELECT 1
              FROM #counted_candidates AS night_evidence

              WHERE night_evidence.emp_id =
                    night_candidate.emp_id

                AND night_evidence.work_date =
                    night_candidate.work_date

                AND night_evidence.candidate_count = 1
          )
    )

    AND EXISTS (
        SELECT 1
        FROM #counted_candidates AS day_evidence

        WHERE day_evidence.emp_id = b.emp_id
          AND day_evidence.work_date = b.work_date
          AND day_evidence.candidate_count = 1

          AND day_evidence.corrected_punch_time >
              b.corrected_punch_time

          AND day_evidence.corrected_punch_time >=
              DATEADD(HOUR, -2, b.scheduled_end)

          AND day_evidence.corrected_punch_time <=
              DATEADD(HOUR, 8, b.scheduled_end)
    );
    -- 5. Never allow one punch to be assigned twice.
    IF EXISTS (
        SELECT _source_row_number
        FROM #resolved_assignments
        GROUP BY _source_row_number
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50120, 'A punch was assigned to multiple shifts.', 1;
        
    CREATE UNIQUE CLUSTERED INDEX IX_resolved_assignments_source
        ON #resolved_assignments (_source_row_number);

    -- Stop rather than silently discard unresolved punches.
    IF EXISTS (
        SELECT 1
        FROM staging.biometric_punches AS p
        WHERE NOT EXISTS (
            SELECT 1
            FROM #resolved_assignments AS a
            WHERE a._source_row_number = p._source_row_number
        )
    )
    BEGIN
        SELECT TOP (20)
            p.emp_id,
            p.punch_id,
            p.corrected_punch_time
        FROM staging.biometric_punches AS p
        WHERE NOT EXISTS (
            SELECT 1
            FROM #resolved_assignments AS a
            WHERE a._source_row_number = p._source_row_number
        )
        ORDER BY p.emp_id, p.corrected_punch_time;

        THROW 50121, 'Unresolved punch assignments require review.', 1;
    END;

    DECLARE @retained_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.biometric_punches);

    IF @retained_count = 0
        THROW 50122, 'No retained punches available for assignment.', 1;

    -- 6. Persist the assignment and its explanation.
    IF OBJECT_ID(N'staging.punch_shift_assignment', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.punch_shift_assignment (
            _source_row_number BIGINT NOT NULL PRIMARY KEY,
            punch_id NVARCHAR(100) NOT NULL UNIQUE,
            emp_id NVARCHAR(50) NOT NULL,
            work_date DATE NOT NULL,
            assignment_method NVARCHAR(200) NOT NULL
        );

        CREATE INDEX IX_punch_assignment_employee_date
            ON staging.punch_shift_assignment (emp_id, work_date);
    END;

    DELETE FROM staging.punch_shift_assignment;

    INSERT INTO staging.punch_shift_assignment (
        _source_row_number,
        punch_id,
        emp_id,
        work_date,
        assignment_method
    )
    SELECT
        _source_row_number,
        punch_id,
        emp_id,
        work_date,
        assignment_method
    FROM #resolved_assignments;

    DECLARE @assigned_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.punch_shift_assignment);

    IF @retained_count <> @assigned_count
        THROW 50123, 'Punch assignment reconciliation failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        @retained_count AS retained_punches,
        @assigned_count AS assigned_punches,
        'PASS' AS reconciliation;

    SELECT
        assignment_method,
        COUNT_BIG(*) AS punch_count
    FROM staging.punch_shift_assignment
    GROUP BY assignment_method
    ORDER BY assignment_method;

    SELECT
        a.emp_id,
        a.punch_id,
        p.corrected_punch_time,
        a.work_date AS assigned_work_date,
        a.assignment_method
    FROM staging.punch_shift_assignment AS a
    INNER JOIN staging.biometric_punches AS p
        ON a._source_row_number = p._source_row_number
    WHERE a.assignment_method LIKE 'DAY boundary:%'
    ORDER BY a.emp_id;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;