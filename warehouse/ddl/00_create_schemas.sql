USE [indus_weave_hr_pipeline];
GO

IF SCHEMA_ID(N'raw') IS NULL
    EXEC(N'CREATE SCHEMA [raw] AUTHORIZATION [dbo];');
GO

IF SCHEMA_ID(N'staging') IS NULL
    EXEC(N'CREATE SCHEMA [staging] AUTHORIZATION [dbo];');
GO

IF SCHEMA_ID(N'warehouse') IS NULL
    EXEC(N'CREATE SCHEMA [warehouse] AUTHORIZATION [dbo];');
GO

IF SCHEMA_ID(N'audit') IS NULL
    EXEC(N'CREATE SCHEMA [audit] AUTHORIZATION [dbo];');
GO

SELECT name AS schema_name
FROM sys.schemas
WHERE name IN ('raw', 'staging', 'warehouse', 'audit')
ORDER BY name;