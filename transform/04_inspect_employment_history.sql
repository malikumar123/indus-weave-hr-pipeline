USE [indus_weave_hr_pipeline];
GO

-- Find multiple history records starting on the same date.
WITH history_dates AS (
    SELECT
        LTRIM(RTRIM(emp_id)) AS emp_id,
        TRY_CONVERT(
            DATE,
            LTRIM(RTRIM(effective_from)),
            23
        ) AS effective_from,
        COUNT(*) AS record_count
    FROM raw.employment_history
    GROUP BY
        LTRIM(RTRIM(emp_id)),
        TRY_CONVERT(
            DATE,
            LTRIM(RTRIM(effective_from)),
            23
        )
)
SELECT *
FROM history_dates
WHERE record_count > 1;


-- Inspect all versions of the affected employee.
SELECT
    emp_id,
    effective_from,
    effective_to,
    dept_id,
    designation,
    grade,
    basic_salary,
    change_reason,
    _source_row_number
FROM raw.employment_history
WHERE LTRIM(RTRIM(emp_id)) = 'E11259'
ORDER BY effective_from, _source_row_number;