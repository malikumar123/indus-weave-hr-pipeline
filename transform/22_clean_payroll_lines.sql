USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #payroll;

    -- 1. Clean text and convert numeric values.
    SELECT
        NULLIF(LTRIM(RTRIM(line_id)), '') AS line_id,
        NULLIF(LTRIM(RTRIM(emp_id)), '') AS emp_id,

        NULLIF(
            LTRIM(RTRIM(payroll_month)), ''
        ) AS source_payroll_month,

        TRY_CONVERT(
            DATE,
            NULLIF(LTRIM(RTRIM(payroll_month)), '') + '-01',
            23
        ) AS payroll_month,

        UPPER(
            NULLIF(LTRIM(RTRIM(component)), '')
        ) AS component,

        UPPER(
            NULLIF(LTRIM(RTRIM(component_type)), '')
        ) AS component_type,

        TRY_CONVERT(
            DECIMAL(18, 4),
            NULLIF(LTRIM(RTRIM(units)), '')
        ) AS units,

        TRY_CONVERT(
            DECIMAL(18, 2),
            NULLIF(LTRIM(RTRIM(amount)), '')
        ) AS amount,

        CASE
            WHEN NULLIF(LTRIM(RTRIM(units)), '') IS NOT NULL
            THEN 1 ELSE 0
        END AS had_units,

        _source_row_number

    INTO #payroll
    FROM raw.payroll_lines;


    -- 2. Validate values and the YYYY-MM month format.
    IF EXISTS (
        SELECT 1
        FROM #payroll
        WHERE line_id IS NULL
           OR emp_id IS NULL
           OR payroll_month IS NULL
           OR source_payroll_month IS NULL
           OR LEN(source_payroll_month) <> 7
           OR source_payroll_month <>
              LEFT(CONVERT(CHAR(10), payroll_month, 23), 7)
           OR component IS NULL
           OR component_type IS NULL
           OR component_type NOT IN ('EARNING', 'DEDUCTION')
           OR amount IS NULL
           OR amount < 0
           OR (had_units = 1 AND units IS NULL)
           OR units < 0
           OR (
               component IN ('OVERTIME', 'ABSENCE_DEDUCTION')
               AND units IS NULL
           )
           OR LEN(line_id) > 100
           OR LEN(emp_id) > 50
    )
        THROW 50150, 'Invalid payroll values or month format.', 1;

    IF EXISTS (
        SELECT 1
        FROM #payroll
        WHERE component NOT IN (
            'BASIC',
            'HOUSE_RENT',
            'MEDICAL',
            'CONVEYANCE',
            'OVERTIME',
            'INCOME_TAX',
            'EOBI',
            'ABSENCE_DEDUCTION',
            'LOAN_INSTALLMENT'
        )
    )
        THROW 50151, 'Unknown payroll component.', 1;

    -- Validate the component's expected classification.
    IF EXISTS (
        SELECT 1
        FROM #payroll
        WHERE (
            component IN (
                'BASIC', 'HOUSE_RENT', 'MEDICAL',
                'CONVEYANCE', 'OVERTIME'
            )
            AND component_type <> 'EARNING'
        )
        OR (
            component IN (
                'INCOME_TAX', 'EOBI',
                'ABSENCE_DEDUCTION', 'LOAN_INSTALLMENT'
            )
            AND component_type <> 'DEDUCTION'
        )
    )
        THROW 50152, 'Payroll component/type mismatch.', 1;

    IF EXISTS (
        SELECT line_id
        FROM #payroll
        GROUP BY line_id
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50153, 'Duplicate payroll line IDs found.', 1;

    IF EXISTS (
        SELECT 1
        FROM #payroll AS p
        LEFT JOIN staging.employees AS e
            ON p.emp_id = e.emp_id
        WHERE e.emp_id IS NULL
    )
        THROW 50154, 'Payroll references an unknown employee.', 1;


    -- 3. Create the typed staging table.
    IF OBJECT_ID(N'staging.payroll_lines', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.payroll_lines (
            line_id NVARCHAR(100) NOT NULL PRIMARY KEY,
            payroll_month DATE NOT NULL,
            emp_id NVARCHAR(50) NOT NULL,
            component NVARCHAR(50) NOT NULL,
            component_type NVARCHAR(20) NOT NULL,
            units DECIMAL(18, 4) NULL,
            amount DECIMAL(18, 2) NOT NULL,
            _source_row_number BIGINT NOT NULL UNIQUE,

            CHECK (DAY(payroll_month) = 1),
            CHECK (component_type IN ('EARNING', 'DEDUCTION')),
            CHECK (amount >= 0),
            CHECK (units IS NULL OR units >= 0)
        );

        CREATE INDEX IX_payroll_employee_month
            ON staging.payroll_lines (emp_id, payroll_month)
            INCLUDE (component, component_type, units, amount);
    END;


    -- 4. Preserve all payroll lines, including suspicious payments.
    DELETE FROM staging.payroll_lines;

    INSERT INTO staging.payroll_lines (
        line_id,
        payroll_month,
        emp_id,
        component,
        component_type,
        units,
        amount,
        _source_row_number
    )
    SELECT
        line_id,
        payroll_month,
        emp_id,
        component,
        component_type,
        units,
        amount,
        _source_row_number
    FROM #payroll;


    -- 5. Reconcile counts and the converted source amount total.
    DECLARE @raw_count BIGINT =
        (SELECT COUNT_BIG(*) FROM raw.payroll_lines);

    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.payroll_lines);

    IF @raw_count <> @staging_count
        THROW 50155, 'Payroll row reconciliation failed.', 1;

    DECLARE @source_amount DECIMAL(38, 2) =
        (SELECT COALESCE(SUM(amount), 0) FROM #payroll);

    DECLARE @staging_amount DECIMAL(38, 2) =
        (SELECT COALESCE(SUM(amount), 0) FROM staging.payroll_lines);

    IF @source_amount <> @staging_amount
        THROW 50156, 'Payroll amount reconciliation failed.', 1;

    COMMIT TRANSACTION;

    -- Result A: Reconciliation.
    SELECT
        @raw_count AS raw_records,
        @staging_count AS staging_records,
        'PASS' AS reconciliation;

    -- Result B: Payroll totals and paid OT hours by month.
    SELECT
        payroll_month,

        SUM(
            CASE WHEN component_type = 'EARNING'
                 THEN amount ELSE 0 END
        ) AS gross_payroll_cost,

        SUM(
            CASE WHEN component_type = 'DEDUCTION'
                 THEN amount ELSE 0 END
        ) AS deductions,

        SUM(
            CASE WHEN component = 'OVERTIME'
                 THEN units ELSE 0 END
        ) AS paid_overtime_hours,

        SUM(
            CASE WHEN component = 'OVERTIME'
                 THEN amount ELSE 0 END
        ) AS overtime_amount

    FROM staging.payroll_lines
    GROUP BY payroll_month
    ORDER BY payroll_month;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;