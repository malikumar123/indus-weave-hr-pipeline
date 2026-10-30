USE [indus_weave_hr_pipeline];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS #leave_decisions;

    -- Check each required approval independently.
    WITH approval_checks AS (
        SELECT
            l.request_id,
            l.cancelled_at,

            CASE WHEN EXISTS (
                SELECT 1
                FROM staging.leave_approvals AS a
                WHERE a.request_id = l.request_id
                  AND a.step = 1
                  AND a.approver_role = 'Manager'
                  AND a.action = 'Approved'
            ) THEN 1 ELSE 0 END AS manager_approved,

            CASE WHEN EXISTS (
                SELECT 1
                FROM staging.leave_approvals AS a
                WHERE a.request_id = l.request_id
                  AND a.step = 2
                  AND a.approver_role = 'HR'
                  AND a.action = 'Approved'
            ) THEN 1 ELSE 0 END AS hr_approved

        FROM staging.leave_requests AS l
    )
    SELECT
        request_id,

        CAST(
            CASE
                WHEN cancelled_at IS NULL
                 AND manager_approved = 1
                 AND hr_approved = 1
                THEN 1
                ELSE 0
            END AS BIT
        ) AS is_approved,

        CASE
            WHEN cancelled_at IS NOT NULL
                THEN 'Cancelled'
            WHEN manager_approved = 0 AND hr_approved = 0
                THEN 'Both required approvals not satisfied'
            WHEN manager_approved = 0
                THEN 'Manager approval not satisfied'
            WHEN hr_approved = 0
                THEN 'HR approval not satisfied'
            ELSE 'Approved'
        END AS decision_reason

    INTO #leave_decisions
    FROM approval_checks;

    IF OBJECT_ID(N'staging.leave_request_status', N'U') IS NULL
    BEGIN
        CREATE TABLE staging.leave_request_status (
            request_id NVARCHAR(100) NOT NULL PRIMARY KEY,
            is_approved BIT NOT NULL,
            decision_reason NVARCHAR(100) NOT NULL,

            FOREIGN KEY (request_id)
                REFERENCES staging.leave_requests(request_id)
        );
    END;

    DELETE FROM staging.leave_request_status;

    INSERT INTO staging.leave_request_status (
        request_id,
        is_approved,
        decision_reason
    )
    SELECT
        request_id,
        is_approved,
        decision_reason
    FROM #leave_decisions;

    DECLARE @request_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.leave_requests);

    DECLARE @classified_count BIGINT =
        (SELECT COUNT_BIG(*) FROM staging.leave_request_status);

    IF @request_count <> @classified_count
        THROW 50090, 'Leave classification reconciliation failed.', 1;

    COMMIT TRANSACTION;

    -- Result A: Every request has a classification.
    SELECT
        @request_count AS requests,
        @classified_count AS classified_requests,
        'PASS' AS reconciliation;

    -- Result B: Explain why requests qualify or do not qualify.
    SELECT
        is_approved,
        decision_reason,
        COUNT_BIG(*) AS request_count
    FROM staging.leave_request_status
    GROUP BY is_approved, decision_reason
    ORDER BY is_approved DESC, decision_reason;

    -- Result C: Approved requests by leave type.
    SELECT
        l.leave_type,
        COUNT_BIG(*) AS approved_requests
    FROM staging.leave_requests AS l
    INNER JOIN staging.leave_request_status AS s
        ON l.request_id = s.request_id
    WHERE s.is_approved = 1
    GROUP BY l.leave_type
    ORDER BY l.leave_type;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;