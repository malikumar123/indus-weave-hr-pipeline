import argparse
import csv
import time
from pathlib import Path

from config.database import get_connection


PROJECT_ROOT = Path(__file__).resolve().parents[1]
QUERY_FOLDER = PROJECT_ROOT / "analytics"
RESULT_FOLDER = QUERY_FOLDER / "results"


def main():
    parser = argparse.ArgumentParser(
        description="Run analytical queries and export CSV results."
    )

    parser.add_argument(
        "--query",
        type=int,
        choices=range(1, 11),
        help="Run one question, numbered 1 to 10. Omit to run all.",
    )

    args = parser.parse_args()

    if args.query is not None:
        pattern = f"q{args.query:02d}_*.sql"
    else:
        pattern = "q[0-9][0-9]_*.sql"

    query_files = sorted(QUERY_FOLDER.glob(pattern))

    if args.query is not None and len(query_files) > 1:
        raise ValueError(
            f"Multiple SQL files found for question {args.query}."
        )

    if not query_files:
        raise FileNotFoundError(
            f"No analytical SQL files found matching {pattern}."
        )

    RESULT_FOLDER.mkdir(parents=True, exist_ok=True)

    run_started = time.perf_counter()
    connection = get_connection()

    try:
        for query_file in query_files:
            sql = query_file.read_text(encoding="utf-8-sig")
            output_file = RESULT_FOLDER / f"{query_file.stem}.csv"
            temporary_file = output_file.with_suffix(".csv.tmp")

            cursor = connection.cursor()
            query_started = time.perf_counter()

            try:
                print(
                    f"\nRUNNING {query_file.name}...",
                    flush=True,
                )

                execute_started = time.perf_counter()
                cursor.execute(sql)
                execute_seconds = (
                    time.perf_counter() - execute_started
                )

                print(
                    f"Execute returned after {execute_seconds:.2f} seconds.",
                    flush=True,
                )

                if cursor.description is None:
                    raise ValueError(
                        f"{query_file.name} returned no result table."
                    )

                columns = [
                    column[0] for column in cursor.description
                ]

                row_count = 0
                fetch_started = time.perf_counter()

                with temporary_file.open(
                    "w", newline="", encoding="utf-8-sig"
                ) as output:
                    writer = csv.writer(output)
                    writer.writerow(columns)

                    while True:
                        rows = cursor.fetchmany(1000)

                        if not rows:
                            break

                        writer.writerows(rows)
                        row_count += len(rows)

                fetch_seconds = time.perf_counter() - fetch_started

                temporary_file.replace(output_file)
                total_seconds = time.perf_counter() - query_started

                print(
                    f"EXPORTED {query_file.name}: "
                    f"{row_count:,} rows -> {output_file.name}",
                    flush=True,
                )

                print(
                    f"TIMING | execute: {execute_seconds:.2f}s"
                    f" | fetch/write: {fetch_seconds:.2f}s"
                    f" | total: {total_seconds:.2f}s",
                    flush=True,
                )

            except Exception:
                elapsed = time.perf_counter() - query_started

                print(
                    f"FAILED {query_file.name} "
                    f"after {elapsed:.2f} seconds.",
                    flush=True,
                )
                raise

            finally:
                cursor.close()
                connection.rollback()

        print(
            f"\nExported {len(query_files)} query result file(s).",
            flush=True,
        )

    finally:
        connection.close()

        print(
            f"Total run time: "
            f"{time.perf_counter() - run_started:.2f} seconds.",
            flush=True,
        )


if __name__ == "__main__":
    main()