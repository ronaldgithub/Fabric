-- Enrichment ("verrijking"): combine both sources, add source system, full name, load date, surrogate key.
-- Both sources use CustomerId = 1, so a surrogate key is needed. Re-runnable (full reload).
IF OBJECT_ID('dwh.Customers') IS NULL
    CREATE TABLE dwh.Customers (
        CustomerKey   int          NOT NULL,
        SourceSystem  varchar(20)  NOT NULL,
        SourceId      int          NOT NULL,
        LastName      varchar(100) NOT NULL,
        Initials      varchar(10)  NULL,
        FullName      varchar(120) NOT NULL,
        LoadDateUtc   datetime2(0) NOT NULL
    );

TRUNCATE TABLE dwh.Customers;

INSERT dwh.Customers (CustomerKey, SourceSystem, SourceId, LastName, Initials, FullName, LoadDateUtc)
SELECT ROW_NUMBER() OVER (ORDER BY SourceSystem, CustomerId),
       SourceSystem, CustomerId, LastName, Initials,
       CONCAT(Initials, '. ', LastName),
       SYSUTCDATETIME()
FROM (
    SELECT 'AzureSQL' AS SourceSystem, CustomerId, LastName, Initials FROM stg.Customer_Azure
    UNION ALL
    SELECT 'LocalSQL', CustomerId, LastName, Initials FROM stg.Customer_Local
) s;
