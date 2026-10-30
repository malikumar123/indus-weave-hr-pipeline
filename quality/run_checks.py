from collections import defaultdict
from uuid import uuid4

from config.database import get_connection


def quote(name):
    """Quote a SQL Server identifier."""
    return "[" + name.replace("]", "]]") + "]"


def qualified(schema, table):
    return f"{quote(schema)}.{quote(table)}"


def mismatch(left, right):
    """Return one failure when two scalar SQL expressions differ."""
    return f"""
        SELECT CAST(
            CASE WHEN ({left}) = ({right}) THEN 0 ELSE 1 END
            AS BIGINT
        );
    """


def build_checks(connection):
    cursor = connection.cursor()
    checks = []

    # Discover all declared primary keys, including composite keys.
    cursor.execute("""
        SELECT
            schema_name.name,
            table_name.name,
            column_name.name
        FROM sys.key_constraints AS key_constraint
        INNER JOIN sys.tables AS table_name
            ON key_constraint.parent_object_id = table_name.object_id
        INNER JOIN sys.schemas AS schema_name
            ON table_name.schema_id = schema_name.schema_id
        INNER JOIN sys.index_columns AS index_column
            ON index_column.object_id = table_name.object_id
           AND index_column.index_id =
               key_constraint.unique_index_id
        INNER JOIN sys.columns AS column_name
            ON column_name.object_id = table_name.object_id
           AND column_name.column_id = index_column.column_id
        WHERE key_constraint.type = 'PK'
          AND schema_name.name IN (
              'raw', 'staging', 'warehouse', 'audit'
          )
        ORDER BY
            schema_name.name,
            table_name.name,
            index_column.key_ordinal;
    """)

    primary_keys = defaultdict(list)

    for schema, table, column in cursor.fetchall():
        primary_keys[(schema, table)].append(column)

    for (schema, table), columns in primary_keys.items():
        target = qualified(schema, table)
        grouped_columns = ", ".join(quote(c) for c in columns)
        null_condition = " OR ".join(
            f"{quote(c)} IS NULL" for c in columns
        )

        checks.append((
            f"PK uniqueness: {schema}.{table}",
            f"""
                SELECT COUNT_BIG(*)
                FROM (
                    SELECT {grouped_columns}
                    FROM {target}
                    GROUP BY {grouped_columns}
                    HAVING COUNT_BIG(*) > 1
                ) AS duplicate_keys;
            """,
        ))

        checks.append((
            f"PK not null: {schema}.{table}",
            f"""
                SELECT COUNT_BIG(*)
                FROM {target}
                WHERE {null_condition};
            """,
        ))

    # Discover foreign keys and their column pairs.
    cursor.execute("""
        SELECT
            fk.object_id,
            fk.name,
            child_schema.name,
            child_table.name,
            child_column.name,
            parent_schema.name,
            parent_table.name,
            parent_column.name
        FROM sys.foreign_keys AS fk
        INNER JOIN sys.foreign_key_columns AS pair
            ON fk.object_id = pair.constraint_object_id
        INNER JOIN sys.tables AS child_table
            ON fk.parent_object_id = child_table.object_id
        INNER JOIN sys.schemas AS child_schema
            ON child_table.schema_id = child_schema.schema_id
        INNER JOIN sys.columns AS child_column
            ON child_column.object_id = child_table.object_id
           AND child_column.column_id = pair.parent_column_id
        INNER JOIN sys.tables AS parent_table
            ON fk.referenced_object_id = parent_table.object_id
        INNER JOIN sys.schemas AS parent_schema
            ON parent_table.schema_id = parent_schema.schema_id
        INNER JOIN sys.columns AS parent_column
            ON parent_column.object_id = parent_table.object_id
           AND parent_column.column_id = pair.referenced_column_id
        WHERE child_schema.name IN (
            'raw', 'staging', 'warehouse', 'audit'
        )
        ORDER BY fk.object_id, pair.constraint_column_id;
    """)

    foreign_keys = defaultdict(list)

    for row in cursor.fetchall():
        foreign_keys[row[0]].append(tuple(row[1:]))

    for pairs in foreign_keys.values():
        name, child_schema, child_table, _, parent_schema, parent_table, _ = (
            pairs[0]
        )

        join_condition = " AND ".join(
            f"p.{quote(pair[6])} = c.{quote(pair[3])}"
            for pair in pairs
        )

        # A nullable composite FK is checked only when all parts exist.
        nonnull_condition = " AND ".join(
            f"c.{quote(pair[3])} IS NOT NULL"
            for pair in pairs
        )

        checks.append((
            f"FK integrity: {name}",
            f"""
                SELECT COUNT_BIG(*)
                FROM {qualified(child_schema, child_table)} AS c
                WHERE {nonnull_condition}
                  AND NOT EXISTS (
                      SELECT 1
                      FROM {qualified(parent_schema, parent_table)} AS p
                      WHERE {join_condition}
                  );
            """,
        ))

    checks.append((
        "Foreign keys enabled and trusted",
        """
            SELECT COUNT_BIG(*)
            FROM sys.foreign_keys AS fk
            INNER JOIN sys.tables AS t
                ON fk.parent_object_id = t.object_id
            INNER JOIN sys.schemas AS s
                ON t.schema_id = s.schema_id
            WHERE s.name IN ('raw', 'staging', 'warehouse', 'audit')
              AND (fk.is_disabled = 1 OR fk.is_not_trusted = 1);
        """,
    ))

    # Account for transformations that deliberately exclude versions.
    staging_counts = {
        "employees":
            "(SELECT COUNT_BIG(*) FROM staging.employees)"
            " + (SELECT COUNT_BIG(*) FROM staging.employee_merge_log)",

        "employment_history":
            "(SELECT COUNT_BIG(*) FROM staging.employment_history)"
            " + (SELECT COUNT_BIG(*) FROM staging.history_resolution_log)",

        "biometric_punches":
            "(SELECT COUNT_BIG(*) FROM staging.biometric_punches)"
            " + (SELECT COUNT_BIG(*) FROM staging.punch_duplicate_log)"
            " + (SELECT COUNT_BIG(*) FROM staging.rejected_punches)",
    }

    direct_tables = [
        "departments", "shifts", "shift_roster", "device_mapping",
        "holidays", "leave_requests", "overtime_requests", "payroll_lines",
    ]

    for table in direct_tables:
        staging_counts[table] = (
            f"SELECT COUNT_BIG(*) FROM staging.{quote(table)}"
        )

    for table, accounted_count in staging_counts.items():
        checks.append((
            f"Raw/staging reconciliation: {table}",
            mismatch(
                f"SELECT COUNT_BIG(*) FROM raw.{quote(table)}",
                accounted_count,
            ),
        ))

    # Applications are ingested but their transformation is a bonus.
    raw_tables = list(staging_counts) + ["applications"]

    for table in raw_tables:
        extension = "json" if table in ("shifts", "leave_requests") else "csv"
        filename = f"{table}.{extension}"

        checks.append((
            f"Raw/ingestion-log count: {table}",
            mismatch(
                f"SELECT COUNT_BIG(*) FROM raw.{quote(table)}",
                "SELECT COALESCE(MAX(source_rows), -1) "
                "FROM audit.file_loads "
                f"WHERE source_file = '{filename}'",
            ),
        ))

    warehouse_counts = [
        ("dim_department", "SELECT COUNT_BIG(*) FROM staging.departments"),
        ("dim_shift", "SELECT COUNT_BIG(*) FROM staging.shifts"),
        ("dim_employee", "SELECT COUNT_BIG(*) FROM staging.employment_history"),
        ("fact_attendance_daily",
         "SELECT COUNT_BIG(*) FROM staging.attendance_daily"),
        ("fact_leave_day", "SELECT COUNT_BIG(*) FROM staging.leave_days"),
        ("fact_overtime_approved",
         "SELECT COUNT_BIG(*) FROM staging.overtime_requests "
         "WHERE status = 'Approved'"),
        ("fact_payroll_line", "SELECT COUNT_BIG(*) FROM staging.payroll_lines"),
        ("fact_employee_month_snapshot",
         "SELECT COUNT_BIG(*) FROM staging.employee_month_department"),
    ]

    for table, source_count in warehouse_counts:
        checks.append((
            f"Warehouse row reconciliation: {table}",
            mismatch(
                f"SELECT COUNT_BIG(*) FROM warehouse.{quote(table)}",
                source_count,
            ),
        ))

    checks.extend([
        (
            "Warehouse date coverage",
            mismatch(
                "SELECT COUNT_BIG(*) FROM warehouse.dim_date "
                "WHERE calendar_date BETWEEN '20260401' AND '20260930'",
                "SELECT CAST(183 AS BIGINT)",
            ),
        ),
        (
            "Employee SCD2 ranges do not overlap",
            """
                SELECT COUNT_BIG(*)
                FROM (
                    SELECT
                        valid_from,
                        valid_to,
                        LEAD(valid_from) OVER (
                            PARTITION BY emp_id ORDER BY valid_from
                        ) AS next_start
                    FROM warehouse.dim_employee
                ) AS ranges
                WHERE valid_to < valid_from
                   OR (
                       next_start IS NOT NULL
                       AND (valid_to IS NULL OR valid_to >= next_start)
                   );
            """,
        ),
        (
            "Attendance accepted statuses",
            """
                SELECT COUNT_BIG(*)
                FROM warehouse.fact_attendance_daily
                WHERE attendance_status IS NULL
                   OR attendance_status NOT IN (
                       'Present', 'Absent', 'On Leave',
                       'Holiday', 'Weekly Off', 'Missing Punch'
                   );
            """,
        ),
        (
            "Attendance valid observed durations",
            """
                SELECT COUNT_BIG(*)
                FROM warehouse.fact_attendance_daily
                WHERE worked_hours < 0
                   OR (
                       punch_count >= 2
                       AND (
                           first_punch_time IS NULL
                           OR last_punch_time IS NULL
                           OR last_punch_time < first_punch_time
                           OR last_punch_time >
                              DATEADD(HOUR, 16, first_punch_time)
                       )
                   )
                   OR (
                       punch_count = 1
                       AND (
                           worked_hours IS NOT NULL
                           OR computed_overtime_hours IS NOT NULL
                       )
                   );
            """,
        ),
        (
            "Leave accepted types",
            """
                SELECT COUNT_BIG(*)
                FROM warehouse.fact_leave_day
                WHERE leave_type IS NULL
                   OR leave_type NOT IN ('Annual', 'Casual', 'Sick');
            """,
        ),
        (
            "Payroll accepted components",
            """
                SELECT COUNT_BIG(*)
                FROM warehouse.fact_payroll_line
                WHERE component IS NULL
                   OR component NOT IN (
                       'BASIC', 'HOUSE_RENT', 'MEDICAL', 'CONVEYANCE',
                       'OVERTIME', 'INCOME_TAX', 'EOBI',
                       'ABSENCE_DEDUCTION', 'LOAN_INSTALLMENT'
                   );
            """,
        ),
    ])

    cursor.close()
    return checks


def main():
    run_id = str(uuid4())
    connection = get_connection()

    # Persist each result independently, including errors.
    connection.autocommit = True

    try:
        cursor = connection.cursor()

        cursor.execute("""
            IF OBJECT_ID(N'audit.dq_results', N'U') IS NULL
            BEGIN
                CREATE TABLE audit.dq_results (
                    result_id BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
                    run_id UNIQUEIDENTIFIER NOT NULL,
                    check_name NVARCHAR(500) NOT NULL,
                    status NVARCHAR(10) NOT NULL,
                    failure_count BIGINT NULL,
                    error_message NVARCHAR(2000) NULL,
                    check_sql NVARCHAR(MAX) NOT NULL,
                    checked_at DATETIME2(6) NOT NULL
                        DEFAULT SYSUTCDATETIME(),

                    CHECK (status IN ('PASS', 'FAIL', 'ERROR'))
                );
            END;
        """)

        checks = build_checks(connection)
        totals = {"PASS": 0, "FAIL": 0, "ERROR": 0}

        print(f"Quality run: {run_id}", flush=True)

        for name, sql in checks:
            failure_count = None
            error_message = None

            try:
                cursor.execute(sql)
                failure_count = int(cursor.fetchone()[0])
                status = "PASS" if failure_count == 0 else "FAIL"

            except Exception as error:
                status = "ERROR"
                error_message = str(error)[:2000]

            cursor.execute("""
                INSERT INTO audit.dq_results (
                    run_id, check_name, status,
                    failure_count, error_message, check_sql
                )
                VALUES (?, ?, ?, ?, ?, ?);
            """,
                run_id,
                name,
                status,
                failure_count,
                error_message,
                sql,
            )

            totals[status] += 1
            print(
                f"{status}: {name} | failures={failure_count}",
                flush=True,
            )

            if error_message:
                print(f"  {error_message}", flush=True)

        print(f"\nSummary: {totals}", flush=True)

        return 1 if totals["FAIL"] or totals["ERROR"] else 0

    finally:
        connection.close()


if __name__ == "__main__":
    raise SystemExit(main())