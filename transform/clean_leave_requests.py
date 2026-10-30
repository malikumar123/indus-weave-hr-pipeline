import json
from datetime import date, datetime

from config.database import get_connection


def parse_timestamp(value):
    """Convert an optional ISO timestamp into a Python datetime."""
    if value is None or str(value).strip() == "":
        return None

    result = datetime.fromisoformat(str(value).strip())

    if result.tzinfo is not None:
        raise ValueError("Unexpected timezone in source timestamp.")

    return result


def required_text(value, label, max_length):
    """Validate and trim a required text value."""
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Missing or invalid {label}")

    result = value.strip()

    if len(result) > max_length:
        raise ValueError(f"{label} exceeds {max_length} characters")

    return result


def optional_text(value, label, max_length):
    if value is None or str(value).strip() == "":
        return None

    return required_text(value, label, max_length)


def flatten_records(raw_rows):
    requests = []
    approvals = []

    request_ids = set()
    approval_keys = set()

    for payload, source_row_number in raw_rows:
        record = json.loads(payload)

        request_id = required_text(
            record["request_id"], "request_id", 100
        )

        if request_id in request_ids:
            raise ValueError(f"Duplicate request ID: {request_id}")

        request_ids.add(request_id)

        emp_id = required_text(
            record["employee"]["emp_id"], "emp_id", 50
        )

        plant = required_text(
            record["employee"]["plant"], "plant", 100
        )

        leave_type = required_text(
            record["leave"]["type"], "leave_type", 50
        )

        from_date = date.fromisoformat(record["leave"]["from"])
        to_date = date.fromisoformat(record["leave"]["to"])

        if to_date < from_date:
            raise ValueError(f"Invalid leave date range: {request_id}")

        submitted_at = parse_timestamp(record["submitted_at"])
        cancelled_at = parse_timestamp(record.get("cancelled_at"))

        if submitted_at is None:
            raise ValueError(f"Missing submission timestamp: {request_id}")

        # Preserve this source value, but never use it to count leave days.
        days_requested = record["leave"]["days_requested"]

        if type(days_requested) is not int or days_requested < 0:
            raise ValueError(f"Invalid days_requested: {request_id}")

        requests.append((
            request_id,
            emp_id,
            plant,
            leave_type,
            from_date,
            to_date,
            days_requested,
            submitted_at,
            cancelled_at,
            source_row_number,
        ))

        steps = record["approvals"]

        if not isinstance(steps, list):
            raise ValueError(f"Invalid approvals list: {request_id}")

        for approval in steps:
            step = approval["step"]

            if type(step) is not int or step < 1:
                raise ValueError(f"Invalid approval step: {request_id}")

            key = (request_id, step)

            if key in approval_keys:
                raise ValueError(f"Duplicate approval step: {key}")

            approval_keys.add(key)

            approvals.append((
                request_id,
                step,
                required_text(
                    approval["approver_role"], "approver_role", 50
                ),
                optional_text(
                    approval.get("approver_id"), "approver_id", 100
                ),
                required_text(
                    approval["action"], "approval action", 50
                ),
                parse_timestamp(approval.get("acted_at")),
            ))

    return requests, approvals


def main():
    connection = get_connection()

    try:
        cursor = connection.cursor()

        cursor.execute("""
            SELECT payload, _source_row_number
            FROM raw.leave_requests
            ORDER BY _source_row_number;
        """)

        raw_rows = cursor.fetchall()
        requests, approvals = flatten_records(raw_rows)

        cursor.execute("""
            IF OBJECT_ID(N'staging.leave_requests', N'U') IS NULL
            BEGIN
                CREATE TABLE staging.leave_requests (
                    request_id NVARCHAR(100) NOT NULL PRIMARY KEY,
                    emp_id NVARCHAR(50) NOT NULL,
                    source_plant NVARCHAR(100) NOT NULL,
                    leave_type NVARCHAR(50) NOT NULL,
                    from_date DATE NOT NULL,
                    to_date DATE NOT NULL,
                    source_days_requested INT NOT NULL,
                    submitted_at DATETIME2(6) NOT NULL,
                    cancelled_at DATETIME2(6) NULL,
                    _source_row_number BIGINT NOT NULL UNIQUE,

                    CHECK (to_date >= from_date)
                );
            END;

            IF OBJECT_ID(N'staging.leave_approvals', N'U') IS NULL
            BEGIN
                CREATE TABLE staging.leave_approvals (
                    request_id NVARCHAR(100) NOT NULL,
                    step INT NOT NULL,
                    approver_role NVARCHAR(50) NOT NULL,
                    approver_id NVARCHAR(100) NULL,
                    action NVARCHAR(50) NOT NULL,
                    acted_at DATETIME2(6) NULL,

                    PRIMARY KEY (request_id, step),

                    FOREIGN KEY (request_id)
                        REFERENCES staging.leave_requests(request_id)
                );
            END;
        """)

        # Delete child records before their parent records.
        cursor.execute("""
    IF OBJECT_ID(N'staging.leave_request_status', N'U') IS NOT NULL
        DELETE FROM staging.leave_request_status;
""")
        cursor.execute("DELETE FROM staging.leave_approvals;")
        cursor.execute("DELETE FROM staging.leave_requests;")

        if requests:
            cursor.executemany("""
                INSERT INTO staging.leave_requests (
                    request_id, emp_id, source_plant, leave_type,
                    from_date, to_date, source_days_requested,
                    submitted_at, cancelled_at, _source_row_number
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, requests)

        if approvals:
            cursor.executemany("""
                INSERT INTO staging.leave_approvals (
                    request_id, step, approver_role,
                    approver_id, action, acted_at
                )
                VALUES (?, ?, ?, ?, ?, ?);
            """, approvals)

        # Validate employee references.
        cursor.execute("""
            SELECT COUNT_BIG(*)
            FROM staging.leave_requests AS l
            LEFT JOIN staging.employees AS e
                ON l.emp_id = e.emp_id
            WHERE e.emp_id IS NULL;
        """)

        if cursor.fetchone()[0] != 0:
            raise ValueError("Leave requests reference unknown employees.")

        cursor.execute("SELECT COUNT_BIG(*) FROM staging.leave_requests;")
        request_count = cursor.fetchone()[0]

        cursor.execute("SELECT COUNT_BIG(*) FROM staging.leave_approvals;")
        approval_count = cursor.fetchone()[0]

        if request_count != len(raw_rows):
            raise ValueError("Leave request reconciliation failed.")

        if approval_count != len(approvals):
            raise ValueError("Approval reconciliation failed.")

        connection.commit()

        print(f"Raw requests: {len(raw_rows):,}")
        print(f"Staging requests: {request_count:,}")
        print(f"Approval steps: {approval_count:,}")
        print("Reconciliation: PASS")

    except Exception:
        connection.rollback()
        raise

    finally:
        connection.close()


if __name__ == "__main__":
    main()