from config.database import get_connection


def main():
    connection = get_connection()

    try:
        cursor = connection.cursor()
        cursor.execute("SELECT DB_NAME(), SUSER_SNAME();")

        database, login = cursor.fetchone()

        print("Connection successful!")
        print(f"Database: {database}")
        print(f"Windows login: {login}")
    finally:
        connection.close()


if __name__ == "__main__":
    main()