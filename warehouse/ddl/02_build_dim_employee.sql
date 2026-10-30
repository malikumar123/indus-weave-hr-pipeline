USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #employee_versions;

    -- 1. Combine employee details with authoritative history.
    SELECT
        h.emp_id,
        e.full_name,
        e.hire_date,
        e.separation_date,
        e.employment_type,
        e.annual_leave_entitlement,
        d.department_key,
        h.designation,
        h.grade,
        h.basic_salary,
        h.change_reason,
        h.effective_from AS valid_from,
        h.effective_to AS valid_to,

        CAST(
            CASE WHEN h.effective_to IS NULL THEN 1 ELSE 0 END
            AS BIT
        ) AS is_current,

        h._source_row_number AS history_source_row_number

    INTO #employee_versions

    FROM staging.employment_history AS h

    LEFT JOIN staging.employees AS e
        ON h.emp_id = e.emp_id

    LEFT JOIN warehouse.dim_department AS d
        ON h.dept_id = d.dept_id;


    -- 2. Validate required attributes and target lengths.
    IF NOT EXISTS (SELECT 1 FROM #employee_versions)
        THROW 50190, 'Employee history input is empty.', 1;

    IF EXISTS (
        SELECT 1
        FROM #employee_versions
        WHERE department_key IS NULL
           OR full_name IS NULL
           OR LTRIM(RTRIM(full_name)) = ''
           OR hire_date IS NULL
           OR employment_type IS NULL
           OR annual_leave_entitlement IS NULL
           OR valid_from IS NULL
           OR designation IS NULL
           OR grade IS NULL
           OR basic_salary IS NULL
           OR basic_salary < 0
           OR annual_leave_entitlement < 0
           OR valid_to < valid_from
           OR LEN(emp_id) > 50
           OR LEN(full_name) > 200
           OR LEN(employment_type) > 50
           OR LEN(designation) > 200
           OR LEN(grade) > 20
           OR LEN(change_reason) > 50
    )
        THROW 50191, 'Employee dimension validation failed.', 1;

    IF EXISTS (
        SELECT emp_id, valid_from
        FROM #employee_versions
        GROUP BY emp_id, valid_from
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50192, 'Duplicate employee version keys found.', 1;

    CREATE UNIQUE CLUSTERED INDEX IX_employee_versions
        ON #employee_versions (emp_id, valid_from);


    -- 3. Create the SCD2 employee dimension.
    IF OBJECT_ID(N'warehouse.dim_employee', N'U') IS NULL
    BEGIN
        CREATE TABLE warehouse.dim_employee (
            employee_key INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
            emp_id NVARCHAR(50) NOT NULL,
            full_name NVARCHAR(200) NOT NULL,
            hire_date DATE NOT NULL,
            separation_date DATE NULL,
            employment_type NVARCHAR(50) NOT NULL,
            annual_leave_entitlement INT NOT NULL,
            department_key INT NOT NULL,
            designation NVARCHAR(200) NOT NULL,
            grade NVARCHAR(20) NOT NULL,
            basic_salary DECIMAL(18, 2) NOT NULL,
            change_reason NVARCHAR(50) NOT NULL,
            valid_from DATE NOT NULL,
            valid_to DATE NULL,
            is_current BIT NOT NULL,
            history_source_row_number BIGINT NOT NULL,

            UNIQUE (emp_id, valid_from),

            FOREIGN KEY (department_key)
                REFERENCES warehouse.dim_department(department_key),

            CHECK (valid_to IS NULL OR valid_to >= valid_from),

            CHECK (
                (valid_to IS NULL AND is_current = 1)
                OR
                (valid_to IS NOT NULL AND is_current = 0)
            ),

            CHECK (basic_salary >= 0),
            CHECK (annual_leave_entitlement >= 0)
        );

        CREATE UNIQUE INDEX IX_employee_one_current_version
            ON warehouse.dim_employee (emp_id)
            WHERE is_current = 1;
    END;


    -- A removed/changed source version key needs an explicit rebuild
    -- strategy once facts reference its surrogate key.
    IF EXISTS (
        SELECT 1
        FROM warehouse.dim_employee AS d
        WHERE NOT EXISTS (
            SELECT 1
            FROM #employee_versions AS s
            WHERE s.emp_id = d.emp_id
              AND s.valid_from = d.valid_from
        )
    )
        THROW 50193, 'Existing version missing from source; review before rebuilding.', 1;


    -- 4. Update existing versions while keeping their employee keys.
    -- This also closes the former latest version when new history arrives.
    UPDATE target
    SET
        target.full_name = source.full_name,
        target.hire_date = source.hire_date,
        target.separation_date = source.separation_date,
        target.employment_type = source.employment_type,
        target.annual_leave_entitlement =
            source.annual_leave_entitlement,
        target.department_key = source.department_key,
        target.designation = source.designation,
        target.grade = source.grade,
        target.basic_salary = source.basic_salary,
        target.change_reason = source.change_reason,
        target.valid_to = source.valid_to,
        target.is_current = source.is_current,
        target.history_source_row_number =
            source.history_source_row_number

    FROM warehouse.dim_employee AS target
    INNER JOIN #employee_versions AS source
        ON target.emp_id = source.emp_id
       AND target.valid_from = source.valid_from;


    -- 5. Insert new versions only.
    INSERT INTO warehouse.dim_employee (
        emp_id,
        full_name,
        hire_date,
        separation_date,
        employment_type,
        annual_leave_entitlement,
        department_key,
        designation,
        grade,
        basic_salary,
        change_reason,
        valid_from,
        valid_to,
        is_current,
        history_source_row_number
    )
    SELECT
        s.emp_id,
        s.full_name,
        s.hire_date,
        s.separation_date,
        s.employment_type,
        s.annual_leave_entitlement,
        s.department_key,
        s.designation,
        s.grade,
        s.basic_salary,
        s.change_reason,
        s.valid_from,
        s.valid_to,
        s.is_current,
        s.history_source_row_number

    FROM #employee_versions AS s
    WHERE NOT EXISTS (
        SELECT 1
        FROM warehouse.dim_employee AS d
        WHERE d.emp_id = s.emp_id
          AND d.valid_from = s.valid_from
    );


    -- 6. Check that version ranges do not overlap.
    IF EXISTS (
        SELECT 1
        FROM (
            SELECT
                emp_id,
                valid_from,
                valid_to,

                LEAD(valid_from) OVER (
                    PARTITION BY emp_id
                    ORDER BY valid_from
                ) AS next_valid_from

            FROM warehouse.dim_employee
        ) AS ranges

        WHERE next_valid_from IS NOT NULL
          AND (
              valid_to IS NULL
              OR valid_to >= next_valid_from
          )
    )
        THROW 50194, 'Overlapping employee dimension ranges found.', 1;

    -- Every employee must have exactly one latest history version.
    IF EXISTS (
        SELECT 1
        FROM staging.employees AS e
        LEFT JOIN warehouse.dim_employee AS d
            ON e.emp_id = d.emp_id
           AND d.is_current = 1
        WHERE d.employee_key IS NULL
    )
        THROW 50195, 'Employee lacks a current history version.', 1;

    DECLARE @expected_versions BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.employment_history);

    DECLARE @actual_versions BIGINT =
        (SELECT COUNT_BIG(*) FROM warehouse.dim_employee);

    IF @expected_versions <> @actual_versions
        THROW 50196, 'Employee dimension reconciliation failed.', 1;

    COMMIT TRANSACTION;

    -- Result A: History version coverage.
    SELECT
        @expected_versions AS staging_history_versions,
        @actual_versions AS warehouse_employee_versions,
        'PASS' AS reconciliation;

    -- Result B: Employees versus versions.
    SELECT
        COUNT(DISTINCT emp_id) AS distinct_employees,
        SUM(CAST(is_current AS BIGINT)) AS current_history_versions
    FROM warehouse.dim_employee;

    -- Result C: Examples of employees with several versions.
    SELECT TOP (15)
        d.employee_key,
        d.emp_id,
        department.dept_name,
        d.grade,
        d.basic_salary,
        d.valid_from,
        d.valid_to,
        d.is_current
    FROM warehouse.dim_employee AS d
    INNER JOIN warehouse.dim_department AS department
        ON d.department_key = department.department_key
    WHERE d.emp_id IN (
        SELECT emp_id
        FROM warehouse.dim_employee
        GROUP BY emp_id
        HAVING COUNT_BIG(*) > 1
    )
    ORDER BY d.emp_id, d.valid_from;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;