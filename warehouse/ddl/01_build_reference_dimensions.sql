USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    -- 1. Department dimension.
    IF OBJECT_ID(N'warehouse.dim_department', N'U') IS NULL
    BEGIN
        CREATE TABLE warehouse.dim_department (
            department_key INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
            dept_id NVARCHAR(50) NOT NULL UNIQUE,
            dept_name NVARCHAR(200) NOT NULL,
            plant NVARCHAR(100) NOT NULL,
            cost_center NVARCHAR(100) NOT NULL,
            previous_name NVARCHAR(200) NULL,
            renamed_on DATE NULL
        );
    END;

    -- Update attributes without changing existing surrogate keys.
    UPDATE target
    SET
        target.dept_name = source.dept_name,
        target.plant = source.plant,
        target.cost_center = source.cost_center,
        target.previous_name = source.previous_name,
        target.renamed_on = source.renamed_on

    FROM warehouse.dim_department AS target
    INNER JOIN staging.departments AS source
        ON target.dept_id = source.dept_id;

    INSERT INTO warehouse.dim_department (
        dept_id, dept_name, plant, cost_center,
        previous_name, renamed_on
    )
    SELECT
        s.dept_id,
        s.dept_name,
        s.plant,
        s.cost_center,
        s.previous_name,
        s.renamed_on
    FROM staging.departments AS s
    WHERE NOT EXISTS (
        SELECT 1
        FROM warehouse.dim_department AS d
        WHERE d.dept_id = s.dept_id
    );


    -- 2. Shift dimension.
    IF OBJECT_ID(N'warehouse.dim_shift', N'U') IS NULL
    BEGIN
        CREATE TABLE warehouse.dim_shift (
            shift_key INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
            shift_code NVARCHAR(20) NOT NULL UNIQUE,
            shift_name NVARCHAR(100) NOT NULL,
            start_time TIME(0) NOT NULL,
            end_time TIME(0) NOT NULL,
            crosses_midnight BIT NOT NULL,
            grace_minutes INT NOT NULL,

            CHECK (grace_minutes >= 0)
        );
    END;

    UPDATE target
    SET
        target.shift_name = source.shift_name,
        target.start_time = source.start_time,
        target.end_time = source.end_time,
        target.crosses_midnight = source.crosses_midnight,
        target.grace_minutes = source.grace_minutes

    FROM warehouse.dim_shift AS target
    INNER JOIN staging.shifts AS source
        ON target.shift_code = source.shift_code;

    INSERT INTO warehouse.dim_shift (
        shift_code, shift_name, start_time, end_time,
        crosses_midnight, grace_minutes
    )
    SELECT
        s.shift_code,
        s.shift_name,
        s.start_time,
        s.end_time,
        s.crosses_midnight,
        s.grace_minutes
    FROM staging.shifts AS s
    WHERE NOT EXISTS (
        SELECT 1
        FROM warehouse.dim_shift AS d
        WHERE d.shift_code = s.shift_code
    );


    -- 3. Date dimension.
    IF OBJECT_ID(N'warehouse.dim_date', N'U') IS NULL
    BEGIN
        CREATE TABLE warehouse.dim_date (
            date_key INT NOT NULL PRIMARY KEY,
            calendar_date DATE NOT NULL UNIQUE,
            calendar_year SMALLINT NOT NULL,
            calendar_month TINYINT NOT NULL,
            day_of_month TINYINT NOT NULL,
            weekday_number TINYINT NOT NULL,
            is_sunday BIT NOT NULL,
            month_start DATE NOT NULL,
            month_end DATE NOT NULL,

            CHECK (weekday_number BETWEEN 1 AND 7)
        );
    END;

    DECLARE @start_date DATE = '20260401';
    DECLARE @end_date DATE = '20260930';

    WITH dates AS (
        SELECT @start_date AS calendar_date

        UNION ALL

        SELECT DATEADD(DAY, 1, calendar_date)
        FROM dates
        WHERE calendar_date < @end_date
    )
    INSERT INTO warehouse.dim_date (
        date_key,
        calendar_date,
        calendar_year,
        calendar_month,
        day_of_month,
        weekday_number,
        is_sunday,
        month_start,
        month_end
    )
    SELECT
        YEAR(calendar_date) * 10000
            + MONTH(calendar_date) * 100
            + DAY(calendar_date),

        calendar_date,
        YEAR(calendar_date),
        MONTH(calendar_date),
        DAY(calendar_date),

        -- Monday = 1, Sunday = 7.
        DATEDIFF(DAY, '19000101', calendar_date) % 7 + 1,

        CASE
            WHEN DATEDIFF(DAY, '19000101', calendar_date) % 7 = 6
            THEN 1 ELSE 0
        END,

        DATEFROMPARTS(
            YEAR(calendar_date), MONTH(calendar_date), 1
        ),

        EOMONTH(calendar_date)

    FROM dates AS source
    WHERE NOT EXISTS (
        SELECT 1
        FROM warehouse.dim_date AS target
        WHERE target.calendar_date = source.calendar_date
    )
    OPTION (MAXRECURSION 366);


    -- 4. Check source dimension coverage.
    IF NOT EXISTS (SELECT 1 FROM staging.departments)
       OR NOT EXISTS (SELECT 1 FROM staging.shifts)
        THROW 50180, 'Reference staging inputs are empty.', 1;

    IF EXISTS (
        SELECT 1
        FROM staging.departments AS s
        LEFT JOIN warehouse.dim_department AS d
            ON s.dept_id = d.dept_id
        WHERE d.department_key IS NULL
    )
        THROW 50181, 'Department dimension coverage failed.', 1;

    IF EXISTS (
        SELECT 1
        FROM staging.shifts AS s
        LEFT JOIN warehouse.dim_shift AS d
            ON s.shift_code = d.shift_code
        WHERE d.shift_key IS NULL
    )
        THROW 50182, 'Shift dimension coverage failed.', 1;

    IF (
        SELECT COUNT_BIG(*)
        FROM warehouse.dim_date
        WHERE calendar_date BETWEEN @start_date AND @end_date
    ) <> DATEDIFF(DAY, @start_date, @end_date) + 1
        THROW 50183, 'Date dimension coverage failed.', 1;

    COMMIT TRANSACTION;

    SELECT
        'dim_department' AS dimension_name,
        COUNT_BIG(*) AS dimension_rows
    FROM warehouse.dim_department

    UNION ALL

    SELECT
        'dim_shift',
        COUNT_BIG(*)
    FROM warehouse.dim_shift

    UNION ALL

    SELECT
        'dim_date',
        COUNT_BIG(*)
    FROM warehouse.dim_date;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;