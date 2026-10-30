import csv
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from config.database import get_connection


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_FOLDER = PROJECT_ROOT / "data" / "raw"

SOURCE_FILES = [
    "employees.csv",
    "employment_history.csv",
    "departments.csv",
    "shifts.json",
    "shift_roster.csv",
    "device_mapping.csv",
    "biometric_punches.csv",
    "holidays.csv",
    "leave_requests.json",
    "overtime_requests.csv",
    "payroll_lines.csv",
    "applications.csv",
]


def quote_identifier(name):
    """Quote a SQL Server table or column name."""
    return "[" + name.replace("]", "]]") + "]"


def read_source(path):
    """Read source values without cleaning or flattening them."""
    if path.suffix == ".csv":
        with path.open(encoding="utf-8-sig", newline="") as source:
            reader = csv.DictReader(source)
            columns = reader.fieldnames

            if not columns or len(columns) != len(set(columns)):
                raise ValueError(f"Missing or duplicate headers: {path.name}")

            rows = []

            for line_number, record in enumerate(reader, start=2):
                if None in record or any(
                    value is None for value in record.values()
                ):
                    raise ValueError(
                        f"{path.name}: malformed CSV at line {line_number}"
                    )

                rows.append([record[column] for column in columns])

        return columns, rows

    with path.open(encoding="utf-8-sig") as source:
        content = json.load(source)

    if path.name == "shifts.json":
        records = content["shifts"]
    else:
        records = content

    if not isinstance(records, list):
        raise ValueError(f"Expected JSON records: {path.name}")

    # Store each complete JSON record as text, keeping nested structures.
    rows = [
        [json.dumps(record, ensure_ascii=False)]
        for record in records
    ]

    return ["payload"], rows


def create_load_log(cursor):
    cursor.execute("""
        IF OBJECT_ID(N'audit.file_loads', N'U') IS NULL
        BEGIN
            CREATE TABLE audit.file_loads (
                source_file NVARCHAR(255) NOT NULL PRIMARY KEY,
                file_hash CHAR(64) NOT NULL,
                table_name NVARCHAR(128) NOT NULL,
                source_rows BIGINT NOT NULL,
                loaded_rows BIGINT NOT NULL,
                loaded_at DATETIME2(6) NOT NULL
            );
        END;
    """)


def create_raw_table(cursor, table_name, source_columns):
    metadata_columns = {
        "_source_file",
        "_loaded_at",
        "_row_hash",
        "_source_row_number",
    }

    if metadata_columns.intersection(source_columns):
        raise ValueError("Source columns conflict with load metadata.")

    definitions = [
        f"{quote_identifier(column)} NVARCHAR(MAX) NULL"
        for column in source_columns
    ]

    definitions.extend([
        "[_source_file] NVARCHAR(255) NOT NULL",
        "[_loaded_at] DATETIME2(6) NOT NULL",
        "[_row_hash] CHAR(64) NOT NULL",
        "[_source_row_number] BIGINT NOT NULL",
        "UNIQUE ([_source_file], [_source_row_number])",
    ])

    cursor.execute(
        "SELECT OBJECT_ID(?, N'U');",
        f"raw.{table_name}",
    )

    if cursor.fetchone()[0] is None:
        cursor.execute(
            f"CREATE TABLE [raw].{quote_identifier(table_name)} "
            f"({', '.join(definitions)});"
        )


def count_loaded_rows(cursor, table_name, source_file):
    cursor.execute(
        f"SELECT COUNT_BIG(*) "
        f"FROM [raw].{quote_identifier(table_name)} "
        f"WHERE [_source_file] = ?;",
        source_file,
    )

    return cursor.fetchone()[0]


def insert_rows(cursor, table_name, source_columns, rows, loaded_at,
                source_file):
    all_columns = source_columns + [
        "_source_file",
        "_loaded_at",
        "_row_hash",
        "_source_row_number",
    ]

    quoted_columns = ", ".join(
        quote_identifier(column) for column in all_columns
    )

    # Keep each SQL statement below SQL Server's parameter limit.
    batch_size = min(100, 2000 // len(all_columns))
    placeholder = "(" + ", ".join(["?"] * len(all_columns)) + ")"

    for start in range(0, len(rows), batch_size):
        batch = rows[start:start + batch_size]
        parameters = []

        for row_number, values in enumerate(batch, start=start + 1):
            row_text = json.dumps(
                values,
                ensure_ascii=False,
                separators=(",", ":"),
            )

            row_hash = hashlib.sha256(
                row_text.encode("utf-8")
            ).hexdigest()

            parameters.extend(values + [
                source_file,
                loaded_at,
                row_hash,
                row_number,
            ])

        statement = (
            f"INSERT INTO [raw].{quote_identifier(table_name)} "
            f"({quoted_columns}) VALUES "
            + ", ".join([placeholder] * len(batch))
        )

        cursor.execute(statement, *parameters)


def load_file(connection, path):
    cursor = connection.cursor()

    try:
        file_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        table_name = path.stem

        cursor.execute("""
            SELECT file_hash, source_rows, loaded_rows
            FROM audit.file_loads
            WHERE source_file = ?;
        """, path.name)

        previous_load = cursor.fetchone()

        if previous_load:
            if previous_load[0] != file_hash:
                raise ValueError(
                    f"{path.name} changed after its first load. "
                    "Stopped to avoid mixing file versions."
                )

            actual_count = count_loaded_rows(
                cursor, table_name, path.name
            )

            if not (
                actual_count == previous_load[1] == previous_load[2]
            ):
                raise ValueError(
                    f"Stored row count mismatch for {path.name}"
                )

            connection.commit()

            print(
                f"SKIP {path.name}: "
                f"{actual_count:,} rows already in raw.{table_name}"
            )
            return

        columns, rows = read_source(path)

        # Store UTC as a timezone-naive value in SQL Server DATETIME2.
        loaded_at = datetime.now(timezone.utc).replace(tzinfo=None)

        create_raw_table(cursor, table_name, columns)

        insert_rows(
            cursor, table_name, columns, rows, loaded_at, path.name
        )

        actual_count = count_loaded_rows(
            cursor, table_name, path.name
        )

        if actual_count != len(rows):
            raise ValueError(
                f"{path.name}: source={len(rows)}, "
                f"database={actual_count}"
            )

        cursor.execute("""
            INSERT INTO audit.file_loads (
                source_file,
                file_hash,
                table_name,
                source_rows,
                loaded_rows,
                loaded_at
            )
            VALUES (?, ?, ?, ?, ?, ?);
        """,
            path.name,
            file_hash,
            f"raw.{table_name}",
            len(rows),
            actual_count,
            loaded_at,
        )

        # Commit the records and their success log together.
        connection.commit()

        print(
            f"LOAD {path.name}: source={len(rows):,}, "
            f"raw.{table_name}={actual_count:,}"
        )

    except Exception:
        connection.rollback()
        raise

    finally:
        cursor.close()


def main():
    missing = [
        filename for filename in SOURCE_FILES
        if not (RAW_FOLDER / filename).is_file()
    ]

    if missing:
        raise FileNotFoundError(
            f"Missing source files: {', '.join(missing)}"
        )

    connection = get_connection()

    try:
        cursor = connection.cursor()
        create_load_log(cursor)
        connection.commit()
        cursor.close()

        for filename in SOURCE_FILES:
            load_file(connection, RAW_FOLDER / filename)

        print("\nRaw ingestion completed successfully.")

    finally:
        connection.close()


if __name__ == "__main__":
    main()