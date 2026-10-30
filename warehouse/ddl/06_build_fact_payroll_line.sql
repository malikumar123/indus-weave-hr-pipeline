USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #payroll_fact;

    IF NOT EXISTS (SELECT 1 FROM staging.payroll_lines)
        THROW 50230, 'Payroll staging input is empty.', 1;


    -- 1. Resolve monthly attribution and dimension keys.
    SELECT
        p.line_id,
        p.emp_id,
        p.payroll_month,
        m.attribution_date,

        employee.employee_key,
        employee.department_key AS employee_department_key,
        department.department_key,
        calendar.date_key AS payroll_month_key,

        p.component,
        p.component_type,
        p.units,
        p.amount

    INTO #payroll_fact

    FROM staging.payroll_lines AS p

    LEFT JOIN staging.employee_month_department AS m
        ON p.emp_id = m.emp_id
       AND p.payroll_month = m.month_start

    LEFT JOIN warehouse.dim_employee AS employee
        ON p.emp_id = employee.emp_id
       AND m.attribution_date >= employee.valid_from
       AND (
           employee.valid_to IS NULL
           OR m.attribution_date <= employee.valid_to
       )

    LEFT JOIN warehouse.dim_department AS department
        ON m.dept_id = department.dept_id

    LEFT JOIN warehouse.dim_date AS calendar
        ON p.payroll_month = calendar.calendar_date;


    -- 2. Validate dimensions and line grain.
    IF EXISTS (
        SELECT 1
        FROM #payroll_fact
        WHERE attribution_date IS NULL
           OR employee_key IS NULL
           OR department_key IS NULL
           OR payroll_month_key IS NULL
    )
    BEGIN
        SELECT TOP (20)
            line_id,
            emp_id,
            payroll_month,
            attribution_date,
            employee_key,
            department_key,
            payroll_month_key
        FROM #payroll_fact
        WHERE attribution_date IS NULL
           OR employee_key IS NULL
           OR department_key IS NULL
           OR payroll_month_key IS NULL;

        THROW 50231, 'Payroll fact dimension lookup failed.', 1;
    END;

    IF EXISTS (
        SELECT line_id
        FROM #payroll_fact
        GROUP BY line_id
        HAVING COUNT_BIG(*) > 1
    )
        THROW 50232, 'Multiple dimension matches for a payroll line.', 1;

    IF EXISTS (
        SELECT 1
        FROM #payroll_fact
        WHERE department_key <> employee_department_key
    )
        THROW 50233, 'Payroll attribution disagrees with employee history.', 1;


    -- 3. Create the fact table.
    IF OBJECT_ID(N'warehouse.fact_payroll_line', N'U') IS NULL
    BEGIN
        CREATE TABLE warehouse.fact_payroll_line (
            line_id NVARCHAR(100) NOT NULL PRIMARY KEY,
            employee_key INT NOT NULL,
            payroll_month_key INT NOT NULL,
            department_key INT NOT NULL,
            attribution_date DATE NOT NULL,

            component NVARCHAR(50) NOT NULL,
            component_type NVARCHAR(20) NOT NULL,
            units DECIMAL(18, 4) NULL,
            amount DECIMAL(18, 2) NOT NULL,

            FOREIGN KEY (employee_key)
                REFERENCES warehouse.dim_employee(employee_key),

            FOREIGN KEY (payroll_month_key)
                REFERENCES warehouse.dim_date(date_key),

            FOREIGN KEY (department_key)
                REFERENCES warehouse.dim_department(department_key),

            CHECK (component_type IN ('EARNING', 'DEDUCTION')),

            CHECK (
                component IN (
                    'BASIC', 'HOUSE_RENT', 'MEDICAL',
                    'CONVEYANCE', 'OVERTIME', 'INCOME_TAX',
                    'EOBI', 'ABSENCE_DEDUCTION', 'LOAN_INSTALLMENT'
                )
            ),

            CHECK (amount >= 0),
            CHECK (units IS NULL OR units >= 0),

            CHECK (
                component <> 'OVERTIME'
                OR units IS NOT NULL
            )
        );

        CREATE INDEX IX_payroll_fact_month_department
            ON warehouse.fact_payroll_line (
                payroll_month_key, department_key
            );

        CREATE INDEX IX_payroll_fact_employee_month
            ON warehouse.fact_payroll_line (
                employee_key, payroll_month_key
            );
    END;


    -- 4. Preserve every payroll line, including suspicious payments.
    DELETE FROM warehouse.fact_payroll_line;

    INSERT INTO warehouse.fact_payroll_line (
        line_id,
        employee_key,
        payroll_month_key,
        department_key,
        attribution_date,
        component,
        component_type,
        units,
        amount
    )
    SELECT
        line_id,
        employee_key,
        payroll_month_key,
        department_key,
        attribution_date,
        component,
        component_type,
        units,
        amount
    FROM #payroll_fact;


    -- 5. Reconcile row counts and individual line values.
    DECLARE @staging_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.payroll_lines);

    DECLARE @warehouse_count BIGINT =
        (SELECT COUNT_BIG(*) FROM warehouse.fact_payroll_line);

    IF @staging_count <> @warehouse_count
        THROW 50234, 'Payroll fact row reconciliation failed.', 1;

    -- EXCEPT also compares NULL units correctly.
    IF EXISTS (
        SELECT
            line_id,
            employee_key,
            payroll_month_key,
            department_key,
            attribution_date,
            component,
            component_type,
            units,
            amount
        FROM #payroll_fact

        EXCEPT

        SELECT
            line_id,
            employee_key,
            payroll_month_key,
            department_key,
            attribution_date,
            component,
            component_type,
            units,
            amount
        FROM warehouse.fact_payroll_line
    )
        THROW 50235, 'Payroll fact line values do not match prepared input.', 1;

    COMMIT TRANSACTION;

    SELECT
        @staging_count AS staging_payroll_lines,
        @warehouse_count AS warehouse_payroll_lines,
        'PASS' AS reconciliation;

    SELECT
        calendar.month_start,

        SUM(
            CASE WHEN fact.component_type = 'EARNING'
                 THEN fact.amount ELSE 0 END
        ) AS gross_payroll_cost,

        SUM(
            CASE WHEN fact.component_type = 'DEDUCTION'
                 THEN fact.amount ELSE 0 END
        ) AS deductions,

        SUM(
            CASE WHEN fact.component = 'OVERTIME'
                 THEN fact.units ELSE 0 END
        ) AS paid_overtime_hours,

        SUM(
            CASE WHEN fact.component = 'OVERTIME'
                 THEN fact.amount ELSE 0 END
        ) AS overtime_amount

    FROM warehouse.fact_payroll_line AS fact
    INNER JOIN warehouse.dim_date AS calendar
        ON fact.payroll_month_key = calendar.date_key

    GROUP BY calendar.month_start
    ORDER BY calendar.month_start;

    DROP TABLE IF EXISTS #payroll_fact;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;