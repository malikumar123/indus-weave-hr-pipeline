import os
from pathlib import Path

import pyodbc
from dotenv import load_dotenv


PROJECT_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(PROJECT_ROOT / ".env")


def get_connection():
    """Open a SQL Server connection using Windows Authentication."""
    required_settings = ["DB_SERVER", "DB_NAME", "DB_DRIVER"]

    missing = [
        name for name in required_settings
        if not os.getenv(name)
    ]

    if missing:
        raise ValueError(
            f"Missing database settings: {', '.join(missing)}"
        )

    connection_string = (
        f"DRIVER={{{os.environ['DB_DRIVER']}}};"
        f"SERVER={os.environ['DB_SERVER']};"
        f"DATABASE={os.environ['DB_NAME']};"
        "Trusted_Connection=yes;"
        "Encrypt=yes;"
        "TrustServerCertificate=yes;"
    )

    return pyodbc.connect(connection_string, timeout=10)