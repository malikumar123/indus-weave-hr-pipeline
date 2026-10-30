"""Run the Indus Weave pipeline from the project root.

SQL scripts own their transactions. Earlier successful steps remain committed
if a later step fails; rerun after fixing the reported cause. The database must
already exist and .env must configure DB_SERVER, DB_NAME and DB_DRIVER.
"""

import argparse
import ast
from datetime import datetime
from pathlib import Path
import re
import subprocess
import sys
import time
import os


PROJECT_ROOT = Path(__file__).resolve().parent
SCHEMA_SCRIPT = "warehouse/ddl/00_create_schemas.sql"
STAGING_BEFORE_LEAVE = [
    "02_clean_employees.sql",
    "03_clean_departments.sql",
    "05_clean_employment_history.sql",
    "06_clean_shifts.sql",
    "07_clean_shift_roster.sql",
    "08_clean_device_mapping.sql",
    "11_map_and_correct_punches.sql",
    "12_deduplicate_punches.sql",
    "13_clean_holidays.sql",
]
STAGING_AFTER_LEAVE = [
    "14_classify_leave_requests.sql",
    "15_expand_leave_days.sql",
    "16_build_employee_schedule.sql",
    "19_assign_punches_to_shifts.sql",
    "20_build_attendance_daily.sql",
    "21_clean_overtime_requests.sql",
    "22_clean_payroll_lines.sql",
    "23_build_employee_month_department.sql",
]
WAREHOUSE_SCRIPTS = [
    "01_build_reference_dimensions.sql",
    "02_build_dim_employee.sql",
    "03_build_fact_attendance_daily.sql",
    "04_build_fact_leave_day.sql",
    "05_build_fact_overtime_approved.sql",
    "06_build_fact_payroll_line.sql",
    "07_build_employee_month_snapshot.sql",
]
SOURCE_FILES = [
    "employees.csv", "employment_history.csv", "departments.csv",
    "shifts.json", "shift_roster.csv", "device_mapping.csv",
    "biometric_punches.csv", "holidays.csv", "leave_requests.json",
    "overtime_requests.csv", "payroll_lines.csv", "applications.csv",
]
# Scoped to the uploaded scripts: GO is standalone, outside strings/comments.
GO_LINE = re.compile(r"^\s*GO\s*(?:--[^\n]*)?$", re.IGNORECASE | re.MULTILINE)
USE_DATABASE = re.compile(r"^\s*USE\s+\[([^\]]+)\]\s*;\s*$", re.IGNORECASE)


def build_steps(skip_export=False):
    steps = [("sql", SCHEMA_SCRIPT), ("python", "ingestion.load_raw")]
    steps.extend(("sql", f"transform/{name}") for name in STAGING_BEFORE_LEAVE)
    steps.append(("python", "transform.clean_leave_requests"))
    steps.extend(("sql", f"transform/{name}") for name in STAGING_AFTER_LEAVE)
    steps.extend(("sql", f"warehouse/ddl/{name}") for name in WAREHOUSE_SCRIPTS)
    steps.append(("python", "quality.run_checks"))
    if not skip_export:
        steps.append(("python", "analytics.export_results"))
    return steps


def sql_batches(sql):
    """Split the standalone GO separators used by these project scripts."""
    return [batch.strip() for batch in GO_LINE.split(sql) if batch.strip()]


def preflight(root, steps, skip_export):
    """Check required local inputs before making database changes."""
    required = {"config/database.py"}
    required.update(
        target if kind == "sql" else target.replace(".", "/") + ".py"
        for kind, target in steps
    )
    required.update(f"data/raw/{name}" for name in SOURCE_FILES)
    missing = sorted(name for name in required if not (root / name).is_file())
    if missing:
        raise FileNotFoundError("Missing project files:\n  " + "\n  ".join(missing))
    for name in sorted(required):
        if name.endswith(".py"):
            ast.parse((root / name).read_text(encoding="utf-8-sig"), filename=name)
    if not skip_export:
        for question in range(1, 11):
            matches = list((root / "analytics").glob(f"q{question:02d}_*.sql"))
            if len(matches) != 1:
                raise ValueError(
                    f"Expected exactly one q{question:02d}_*.sql; found {len(matches)}."
                )
    # Prevent hardcoded USE statements from sending SQL to a different database
    # than the Python ingestion, quality, and export connections.
    configured_name = os.environ["DB_NAME"]
    for kind, target in steps:
        if kind != "sql":
            continue
        for line in (root / target).read_text(encoding="utf-8-sig").splitlines():
            match = USE_DATABASE.fullmatch(line)
            if match and match.group(1).casefold() != configured_name.casefold():
                raise ValueError(
                    f"{target} uses database {match.group(1)!r}, "
                    f"but DB_NAME is {configured_name!r}. Align them before running."
                )


def consume_results(cursor):
    """Fetch every result and advance every set, surfacing later SQL errors."""
    tables = 0
    rows = 0
    while True:
        if cursor.description is not None:
            tables += 1
            while True:
                batch = cursor.fetchmany(1000)
                if not batch:
                    break
                rows += len(batch)
        if not cursor.nextset():
            return tables, rows


def run_sql(path, connect, emit):
    connection = connect()
    # The uploaded scripts explicitly BEGIN/COMMIT/ROLLBACK their transactions.
    # Avoid an extra implicit pyodbc transaction wrapping those statements.
    connection.autocommit = True
    cursor = None
    try:
        cursor = connection.cursor()
        for number, batch in enumerate(sql_batches(path.read_text(encoding="utf-8-sig")), 1):
            try:
                cursor.execute(batch)
                tables, rows = consume_results(cursor)
                emit(f"  SQL batch {number}: {tables} result table(s), {rows:,} result rows")
            except Exception as error:
                raise RuntimeError(f"{path.name}, SQL batch {number}: {error}") from error
        cursor.execute("SELECT @@TRANCOUNT;")
        if cursor.fetchone()[0] != 0:
            raise RuntimeError(f"{path.name} left an open transaction; rolling it back.")
        consume_results(cursor)
    finally:
        # Closing a connection rolls back any still-open transaction. Explicitly
        # attempt cleanup as well, including when a script fails or is cancelled.
        try:
            if cursor is not None:
                cursor.close()
        finally:
            try:
                cleanup = connection.cursor()
                try:
                    cleanup.execute("IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;")
                    consume_results(cleanup)
                finally:
                    cleanup.close()
            except Exception:
                pass
            finally:
                connection.close()


def run_module(module, root, emit):
    environment = os.environ.copy()
    environment["PYTHONUNBUFFERED"] = "1"
    environment["PYTHONIOENCODING"] = "utf-8"
    process = subprocess.Popen(
        [sys.executable, "-u", "-m", module],
        cwd=root, env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace",
    )
    try:
        for line in process.stdout:
            emit(line.rstrip("\r\n"))
        code = process.wait()
        if code:
            raise RuntimeError(f"{module} exited with code {code}.")
    except BaseException:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        raise
    finally:
        process.stdout.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", action="store_true", help="Print step order only; no database access.")
    parser.add_argument("--skip-export", action="store_true", help="Build and validate without rerunning analytical exports.")
    args = parser.parse_args(argv)
    steps = build_steps(args.skip_export)
    if args.plan:
        for number, (kind, target) in enumerate(steps, 1):
            print(f"{number:02d}. {kind.upper():6s} {target}")
        print("Plan only: no files executed and no database connection opened.")
        return 0

    log_folder = PROJECT_ROOT / "logs"
    log_folder.mkdir(exist_ok=True)
    log_path = log_folder / f"pipeline_{datetime.now():%Y%m%d_%H%M%S_%f}.log"
    started = time.perf_counter()
    current_step = "preflight"
    with log_path.open("w", encoding="utf-8") as log:
        def emit(message):
            print(message, flush=True)
            log.write(message + "\n")
            log.flush()

        emit(f"Pipeline started: {datetime.now():%Y-%m-%d %H:%M:%S}")
        emit(f"Log: {log_path}")
        try:
            from config.database import get_connection

            # get_connection's environment loader runs on import. Validate the
            # settings before inspecting hardcoded USE statements.
            missing = [name for name in ("DB_SERVER", "DB_NAME", "DB_DRIVER") if not os.getenv(name)]
            if missing:
                raise ValueError("Missing database settings: " + ", ".join(missing))
            preflight(PROJECT_ROOT, steps, args.skip_export)
            probe = get_connection()
            try:
                cursor = probe.cursor()
                try:
                    cursor.execute("SELECT DB_NAME();")
                    actual = cursor.fetchone()[0]
                    if actual.casefold() != os.environ["DB_NAME"].casefold():
                        raise RuntimeError("Connected database does not match DB_NAME.")
                    emit(f"Database connection verified: {actual}")
                finally:
                    cursor.close()
            finally:
                probe.close()
            for number, (kind, target) in enumerate(steps, 1):
                current_step = target
                step_started = time.perf_counter()
                emit(f"\n[{number}/{len(steps)}] RUNNING {target}")
                if kind == "sql":
                    run_sql(PROJECT_ROOT / target, get_connection, emit)
                else:
                    run_module(target, PROJECT_ROOT, emit)
                emit(f"DONE {target} | {time.perf_counter() - step_started:.2f}s")
            emit("\nPIPELINE PASSED" + (" (analytics exports skipped)." if args.skip_export else "."))
            return 0
        except KeyboardInterrupt:
            emit(f"\nPIPELINE CANCELLED during {current_step}.")
            emit("Earlier completed steps remain committed; rerun after reviewing the log.")
            return 130
        except Exception as error:
            emit(f"\nPIPELINE FAILED during {current_step}: {error}")
            emit("No later steps were run. Earlier completed steps remain committed.")
            return 1
        finally:
            emit(f"Total pipeline time: {time.perf_counter() - started:.2f}s")


if __name__ == "__main__":
    raise SystemExit(main())
