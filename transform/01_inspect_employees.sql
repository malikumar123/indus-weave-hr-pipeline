USE [indus_weave_hr_pipeline];
GO

-- A. Confirm the ingestion audit.
SELECT
    source_file,
    source_rows,
    loaded_rows,
    CASE
        WHEN source_rows = loaded_rows THEN 'PASS'
        ELSE 'FAIL'
    END AS row_count_check
FROM audit.file_loads
ORDER BY source_file;


-- B. Inspect date formats without changing source values.
SELECT TOP (20)
    emp_id,
    date_of_birth,
    hire_date,
    separation_date,
    updated_at
FROM raw.employees
ORDER BY _source_row_number;


-- C. Show every version of employees with repeated IDs.
WITH duplicate_ids AS (
    SELECT emp_id
    FROM raw.employees
    GROUP BY emp_id
    HAVING COUNT(*) > 1
)
SELECT
    e.emp_id,
    e.full_name,
    e.department,
    e.grade,
    e.updated_at,
    e._source_row_number
FROM raw.employees AS e
INNER JOIN duplicate_ids AS d
    ON e.emp_id = d.emp_id
ORDER BY
    e.emp_id,
    e.updated_at,
    e._source_row_number;


-- D. Check that all update timestamps can be parsed.
SELECT
    emp_id,
    updated_at,
    _source_row_number
FROM raw.employees
WHERE TRY_CONVERT(
    DATETIME2(6),
    NULLIF(LTRIM(RTRIM(updated_at)), ''),
    126
) IS NULL;