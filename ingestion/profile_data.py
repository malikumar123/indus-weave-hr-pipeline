import csv
import json
from collections import Counter
from pathlib import Path

# Locate the project folder regardless of where the command is run.
PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_FOLDER = PROJECT_ROOT / "data" / "raw"

EXPECTED_FILES = {
    "applications.csv",
    "biometric_punches.csv",
    "departments.csv",
    "device_mapping.csv",
    "employees.csv",
    "employment_history.csv",
    "holidays.csv",
    "leave_requests.json",
    "overtime_requests.csv",
    "payroll_lines.csv",
    "shifts.json",
    "shift_roster.csv",
}


def profile_csv(file_path):
    with file_path.open(
        encoding="utf-8-sig", newline=""
    ) as source_file:
        reader = csv.DictReader(source_file)
        columns = reader.fieldnames

        if not columns:
            raise ValueError(f"No header found: {file_path.name}")

        rows = list(reader)

    print(f"\nFILE: {file_path.name}")
    print(f"Records: {len(rows):,}")
    print(f"Columns: {', '.join(columns)}")

    # Validate structure before calculating statistics.
    for line_number, row in enumerate(rows, start=2):
        if None in row or any(value is None for value in row.values()):
            raise ValueError(
                f"{file_path.name}: malformed CSV at line {line_number}"
            )

    blank_counts = {
        column: sum(not row[column].strip() for row in rows)
        for column in columns
    }

    print(
        "Blank values:",
        {column: count for column, count in blank_counts.items() if count},
    )

    unique_rows = {
        tuple(row[column] for column in columns)
        for row in rows
    }

    print(f"Exact duplicate records: {len(rows) - len(unique_rows):,}")

    if file_path.name == "employees.csv":
        employee_counts = Counter(row["emp_id"] for row in rows)

        print(f"Unique employee IDs: {len(employee_counts):,}")
        print(
            "Employee IDs appearing more than once:",
            sum(count > 1 for count in employee_counts.values()),
        )
        print(
            "Extra records beyond one per employee:",
            sum(count - 1 for count in employee_counts.values()),
        )


def profile_json(file_path):
    with file_path.open(encoding="utf-8-sig") as source_file:
        content = json.load(source_file)

    # Shifts are wrapped in {"shifts": [...]}; leave is a list.
    if file_path.name == "shifts.json":
        records = content["shifts"]
    else:
        records = content

    if not isinstance(records, list):
        raise ValueError(f"Expected a list of records: {file_path.name}")

    print(f"\nFILE: {file_path.name}")
    print(f"Records: {len(records):,}")

    if records:
        print(f"Top-level fields: {', '.join(records[0].keys())}")


def main():
    if not RAW_FOLDER.is_dir():
        raise FileNotFoundError(f"Source folder not found: {RAW_FOLDER}")

    available_files = {
        path.name for path in RAW_FOLDER.iterdir() if path.is_file()
    }
    missing_files = EXPECTED_FILES - available_files

    if missing_files:
        raise FileNotFoundError(
            f"Missing source files: {', '.join(sorted(missing_files))}"
        )

    print("HR SOURCE DATA PROFILE")
    print(f"Source folder: {RAW_FOLDER}")

    for filename in sorted(EXPECTED_FILES):
        file_path = RAW_FOLDER / filename

        if file_path.suffix == ".csv":
            profile_csv(file_path)
        else:
            profile_json(file_path)

    print("\nProfiling completed. Source files were not changed.")


if __name__ == "__main__":
    main()