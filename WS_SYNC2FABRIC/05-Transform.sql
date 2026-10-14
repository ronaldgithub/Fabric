-- Enrichment ("verrijking"): combine both sources, add source system, full name, load date, surrogate key.
-- Both sources use CustomerId = 1, so a surrogate key is needed. Re-runnable (full reload).

-- Target table in the dwh schema (schema is created in step 04). Created only when missing.
-- CustomerKey is the surrogate key: unique across both sources. SourceSystem + SourceId
-- keep the link back to the original row.
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

-- Full reload: empty the table, then rebuild it from staging. Simple and safe for a tiny demo.
TRUNCATE TABLE dwh.Customers;

INSERT dwh.Customers (CustomerKey, SourceSystem, SourceId, LastName, Initials, FullName, LoadDateUtc)
SELECT ROW_NUMBER() OVER (ORDER BY SourceSystem, CustomerId),  -- surrogate key: 1..n, stable for the same input
       SourceSystem, CustomerId, LastName, Initials,
       CONCAT(Initials, '. ', LastName),                        -- e.g. 'A. Jansen'
       SYSUTCDATETIME()                                         -- when this row was loaded (UTC)
FROM (
    -- UNION ALL (not UNION): keep both rows even if they look alike; they come from different systems.
    SELECT 'AzureSQL' AS SourceSystem, CustomerId, LastName, Initials FROM stg.Customer_Azure
    UNION ALL
    SELECT 'LocalSQL', CustomerId, LastName, Initials FROM stg.Customer_Local
) s;
