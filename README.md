# Indus Weave HR Data Pipeline

A Python and SQL Server project that reconciles employee history,
biometric attendance, leave, overtime, and payroll data.

**Reporting period:** 1 April–30 September 2026  
**Company:** Indus Weave Textiles — fictional, synthetic dataset  
**Technology:** Python, SQL Server Express, pyodbc, SSMS

## Objectives

- Preserve original source values in a raw database layer.
- Clean records with traceable exclusions and reconciliations.
- Build daily attendance from biometric punches and shift schedules.
- Preserve employee history using a Type 2 dimension.
- Answer ten business questions using SQL and exported CSVs.
- Run automated data-quality checks.
- Automate ingestion, transformations, warehouse loading, and validation.

## Project structure

| Location | Purpose |
|---|---|
| data/raw/ | Original source files |
| config/database.py | Database connection |
| ingestion/ | Source profiling and raw ingestion |
| transform/ | Staging transformations and diagnostic SQL |
| warehouse/ddl/ | Schema, dimension, and fact scripts |
| analytics/ | Ten analytical SQL queries and exporter |
| analytics/results/ | Exported CSV results |
| quality/run_checks.py | Automated quality checks |
| docs/warehouse_erd.md | Warehouse ERD |
| presentation/cfo_findings.md | Three CFO findings |
| run_pipeline.py | Automated pipeline runner |
| logs/ | Pipeline execution logs |

## Prerequisites

- Python with virtual environment support
- SQL Server Express or another compatible SQL Server edition
- Microsoft ODBC Driver 18 for SQL Server
- SQL Server Management Studio for initial database setup
- Original dataset files in data/raw/

Run project commands from the project root.

## Setup

### 1. Create the Python environment

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

Alternatively, use the virtual environment's Python directly
without activating it.

### 2. Create the database

Run in SSMS:

```sql
IF DB_ID(N'indus_weave_hr_pipeline') IS NULL
BEGIN
    CREATE DATABASE [indus_weave_hr_pipeline];
END;
GO
```

The SQL scripts use this database name. If using a different name,
update their USE statements and the DB_NAME setting consistently.

### 3. Configure the connection

Create a project-root .env file:

```dotenv
DB_SERVER=YOUR_SERVER\SQLEXPRESS
DB_NAME=indus_weave_hr_pipeline
DB_DRIVER=ODBC Driver 18 for SQL Server
```

Replace YOUR_SERVER with your actual server name.

The connection uses Windows Authentication. The configuration
enables encryption and trusts the server certificate for the
local development connection.

Keep .env out of Git. Commit .env.example with placeholders.

### 4. Add the source files

Place these original files in data/raw/:

- employees.csv
- employment_history.csv
- departments.csv
- shifts.json
- shift_roster.csv
- device_mapping.csv
- biometric_punches.csv
- holidays.csv
- leave_requests.json
- overtime_requests.csv
- payroll_lines.csv
- applications.csv

## Automated execution

### Preview the execution order

```powershell
.\.venv\Scripts\python.exe run_pipeline.py --plan
```

This prints the plan without executing scripts or connecting
to the database.

### Build and validate without analytical exports

```powershell
.\.venv\Scripts\python.exe run_pipeline.py --skip-export
```

This runs 28 steps:

- Create database schemas.
- Ingest or verify raw files.
- Build staging tables.
- Clean and classify leave requests.
- Build employee schedules and attendance.
- Build warehouse dimensions and facts.
- Run automated quality checks.

Existing analytical CSVs are retained.

### Include all analytical exports

```powershell
.\.venv\Scripts\python.exe run_pipeline.py
```

This adds a final step that executes all ten analytical queries
and exports their results.

### Verified execution

A rebuild against the existing populated database completed:

```text
PIPELINE PASSED (analytics exports skipped).
Total pipeline time: 202.45 seconds.

Summary: {'PASS': 129, 'FAIL': 0, 'ERROR': 0}
```

This verifies the 28-step rebuild on the development database.
A complete empty-database run and the combined 29-step run
including exports have not yet been verified.

### Failure handling

- The runner stops when a step fails.
- Failed or errored quality checks produce a nonzero exit code.
- SQL scripts manage their own transactions.
- Earlier successful steps remain committed if a later step fails.
- SQL results are consumed so errors from later statements are detected.
- Execution output and step timings are saved under logs/.

After fixing a failure, rerun the pipeline. It does not currently
support resuming automatically from an individual step.

## Raw ingestion and repeat runs

Raw ingestion preserves source values and adds provenance metadata:

- _source_file
- _loaded_at
- _row_hash
- _source_row_number

Load records are stored in audit.file_loads.

Unchanged files with matching recorded counts are skipped.
Changed files stop ingestion rather than silently mixing file versions.

The current loader is intended for the supplied fixed dataset;
it does not implement automatic replacement of changed source files.

## Manual execution order

The runner is the recommended execution method. For inspection
or troubleshooting, scripts can also be run individually.

Run warehouse/ddl/00_create_schemas.sql before ingestion.

### Raw ingestion

```powershell
.\.venv\Scripts\python.exe -m ingestion.load_raw
```

Optional source profiling:

```powershell
.\.venv\Scripts\python.exe -m ingestion.profile_data
```

### Staging: first group

Run these SQL files in SSMS in order:

1. transform/02_clean_employees.sql
2. transform/03_clean_departments.sql
3. transform/05_clean_employment_history.sql
4. transform/06_clean_shifts.sql
5. transform/07_clean_shift_roster.sql
6. transform/08_clean_device_mapping.sql
7. transform/11_map_and_correct_punches.sql
8. transform/12_deduplicate_punches.sql
9. transform/13_clean_holidays.sql

### Python leave transformation

Run before SQL script 14:

```powershell
.\.venv\Scripts\python.exe -m transform.clean_leave_requests
```

### Staging: second group

Continue in SSMS:

1. transform/14_classify_leave_requests.sql
2. transform/15_expand_leave_days.sql
3. transform/16_build_employee_schedule.sql
4. transform/19_assign_punches_to_shifts.sql
5. transform/20_build_attendance_daily.sql
6. transform/21_clean_overtime_requests.sql
7. transform/22_clean_payroll_lines.sql
8. transform/23_build_employee_month_department.sql

If the Python leave cleaner is rerun, regenerate leave
classification and dependent staging and warehouse results.

### Warehouse

Run these files in order:

1. warehouse/ddl/01_build_reference_dimensions.sql
2. warehouse/ddl/02_build_dim_employee.sql
3. warehouse/ddl/03_build_fact_attendance_daily.sql
4. warehouse/ddl/04_build_fact_leave_day.sql
5. warehouse/ddl/05_build_fact_overtime_approved.sql
6. warehouse/ddl/06_build_fact_payroll_line.sql
7. warehouse/ddl/07_build_employee_month_snapshot.sql

### Optional diagnostics

These scripts are excluded from the automated rebuild:

- 01_inspect_employees.sql
- 04_inspect_employment_history.sql
- 09_inspect_biometric_punches.sql
- 10_inspect_clock_monthly.sql
- 17_inspect_shift_transitions.sql
- 18_inspect_punch_assignments.sql
- 24_compare_monthly_overtime.sql

Some diagnostic queries use temporary tables. Their required
preceding statements must run in the same SSMS session.

## Warehouse model

The warehouse contains four dimensions and five fact tables.

| Table | Grain |
|---|---|
| dim_department | One department |
| dim_shift | One shift definition |
| dim_date | One calendar date |
| dim_employee | One effective-dated employee history version |
| fact_attendance_daily | One employee per work date |
| fact_leave_day | One eligible approved leave day per request |
| fact_overtime_approved | One approved overtime request |
| fact_payroll_line | One payroll component line |
| fact_employee_month_snapshot | One employee per reporting month |

dim_employee uses Slowly Changing Dimension Type 2.
Facts reference the employee version applicable to their
attribution date.

See the [warehouse ERD](docs/warehouse_erd.md).

## Data-quality checks

Run independently:

```powershell
.\.venv\Scripts\python.exe -m quality.run_checks
```

Results are stored in audit.dq_results with a run identifier,
status, failure count, SQL text, and error details when applicable.

Checks include:

- Declared primary-key uniqueness and non-null values
- Foreign-key integrity and enabled/trusted status
- Raw-to-staging row reconciliation
- Raw-to-ingestion-log count reconciliation
- Staging-to-warehouse row reconciliation
- Reporting-date coverage
- Employee history interval overlap
- Accepted attendance statuses
- Observed attendance duration rules
- Accepted leave types
- Accepted payroll components

Recorded result:

```text
PASS: 129
FAIL: 0
ERROR: 0
```

The check count can change when database constraints or checks change.
Passing these checks does not establish that every possible business
exception has been tested.

## Analytics and CSV exports

Run one question:

```powershell
.\.venv\Scripts\python.exe -m analytics.export_results --query 6
```

Run all analytical queries without rebuilding the database:

```powershell
.\.venv\Scripts\python.exe -m analytics.export_results
```

Results are written to analytics/results/.

The exporter reports execution and fetch/write timings.
It writes a temporary CSV before replacing the final output.

Analytics SQL files are executed directly through pyodbc.
Do not add SSMS GO separators to those files.

| Question | SQL file | Recorded rows |
|---|---|---:|
| 1. Month-end headcount by plant and department | q01_headcount.sql | 150 |
| 2. Monthly attrition by department | q02_attrition.sql | 150 |
| 3. Absenteeism by plant and month | q03_absenteeism.sql | 24 |
| 4. Top ten employees by late arrivals | q04_late_arrivals.sql | 10 |
| 5. Observed, approved, and paid overtime | q05_overtime_comparison.sql | 150 |
| 6. Paid overtime more than 15% above observed | q06_overtime_excess.sql | 5 |
| 7. Positive earnings with zero recorded punches | q07_paid_zero_attendance.sql | 58 |
| 8. Positive earnings in months after separation | q08_paid_after_separation.sql | 21 |
| 9. Payroll cost per employee and monthly change | q09_payroll_cost_per_employee.sql | 150 |
| 10. Annual leave above full-year entitlement | q10_annual_leave_excess.sql | 20 |

Counts describe the recorded exports for the supplied dataset.

## Business rules and assumptions

### Employee history

- Keep the employee record with the latest updated_at.
- Use employment history for department, grade, and salary over time.
- Derive each history end date from the next effective start date.
- Keep the latest history version open-ended.
- Resolve the conflicting same-day Hire and Salary Revision records
  by retaining Salary Revision and logging the excluded record.
  This is a documented resolution assumption.
- is_current identifies the latest history version, not active employment.

### Department attribution

- Daily attendance, leave, and approved overtime use the department
  applicable on the relevant date.
- Monthly measures use the department at month-end, or the last
  working day for separated employees.
- Monthly overtime comparisons use the employee-month snapshot
  to apply consistent department attribution.

### Headcount

Month-end headcount includes employees whose hire date is on or
before month-end and whose separation date is absent or strictly
after month-end.

### Biometric processing

- Match punches using both device_id and device_user_id.
- Log rejected punches that cannot be mapped.
- Apply a minus-60-minute correction to DEV-SITE-01 source timestamps
  on or after 1 July 2026.
- Treat consecutive employee punches within 120 seconds as a
  duplicate chain and retain the earliest punch.
- Attribute NIGHT attendance to the shift start date.
- Search nearby schedules from 120 minutes before start through
  eight hours after end. This is an implementation assumption.
- Preserve equal-distance candidates for review.
- Resolve six exact NIGHT/DAY boundary ties using supporting daytime
  checkout evidence and the absence of unique NIGHT evidence.

### Attendance and overtime

- Apply the defined attendance-status priority.
- Single-punch days have unknown worked duration and observed overtime.
- Late arrivals exceed the ten-minute grace period.
- Report the full delay after scheduled start rather than subtracting grace.
- Floor observed overtime to half-hour increments.
- Incomplete punches can understate observed overtime.

### Leave

- Require the specified Manager and HR approvals.
- Exclude cancelled requests.
- Expand approved requests into individual dates.
- Exclude Sundays and applicable holidays.
- Use eligible leave days rather than source days_requested.
- Compare six-month Annual leave usage against full-year entitlement,
  without prorating entitlement.

### Analytical definitions

- Attrition uses separations divided by the average of opening
  and closing headcount. This average is an analytical assumption.
- Absenteeism excludes weekly offs, holidays, and approved leave.
  Missing Punch days remain in the denominator.
- Q07 defines zero attendance as zero recorded punches.
  A single punch counts as attendance evidence.
- Q08 flags payroll months after the separation month because actual
  payment dates are unavailable.
- Q09 uses total earnings before deductions divided by month-end
  headcount. Payments after separation remain included in payroll cost.
- April month-over-month change is NULL because March is outside
  the reporting period.

## Recorded reconciliations

| Measure | Rows |
|---|---:|
| Raw biometric punches | 345,280 |
| Rejected biometric punches | 6,962 |
| Duplicate biometric punches removed | 16,175 |
| Retained and assigned punches | 322,143 |
| Daily attendance rows | 217,584 |
| Eligible approved leave days | 8,604 |
| Approved overtime requests | 19,666 |
| Payroll lines | 53,617 |
| Employee-month snapshots | 7,449 |
| Employee history versions | 3,685 |

Biometric reconciliation:

```text
345,280 = 6,962 rejected + 16,175 duplicates + 322,143 retained
```

## CFO findings

### 1. Widening overtime gap in Faisalabad Stitching

Faisalabad Stitching exceeded the 15% review threshold in five
months. Across May–September, paid overtime exceeded observed
overtime by 2,915.5 hours.

Incomplete punch records mean this difference is a review
indicator, not confirmed overpayment.

### 2. Payroll earnings after separation

Twenty-one employee-month cases had positive earnings in months
after separation.

Recurring payments require review against payroll removal,
final settlements, and arrears documentation.

### 3. Annual leave above entitlement

Twenty employees exceeded their full-year Annual leave
entitlement using approved eligible days within April–September.

Review leave balances and any authorized exceptions.

See [CFO findings](presentation/cfo_findings.md) for supporting
evidence, actions, and limitations.

## Operational notes

During development, insufficient free space on C: contributed
to a transaction-log-full failure.

The project database's data and log files were relocated to
D:\SQLData. A subsequent 28-step rebuild passed.

This location is specific to the development machine. Other
users can use a suitable SQL Server data location with adequate
free space and service-account permissions.

Earlier intermittent buffer-pool memory errors and variable
query timings remain a performance limitation. The successful
rebuild does not establish that all memory issues are resolved.

## Limitations

- Incomplete biometric records may understate observed overtime.
- Review flags do not prove improper payment or financial loss.
- Actual payment dates are unavailable.
- Supplied data does not establish authorized leave carry-forward
  or additional entitlement exceptions.
- Applications data is ingested into raw; recruitment analytics
  are outside the ten implemented questions.
- Changed source-file replacement is not automated.
- Rebuild verification was performed against an existing database.
- Performance depends on local SQL Server resources.

## Submission status

- [x] Raw ingestion and provenance metadata
- [x] Staging transformations and attendance processing
- [x] Warehouse dimensions and facts
- [x] Ten analytical SQL queries
- [x] Ten CSV result exports
- [x] Automated quality checks
- [x] Warehouse ERD
- [x] Three CFO findings
- [x] Verified automated rebuild without analytical exports
- [ ] Final presentation, maximum six slides
- [ ] Final repository review and GitHub submission