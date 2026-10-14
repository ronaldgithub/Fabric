# Step 2: local Win10 SQL Server db1.dbo.Customer with (1, Pietersen, B). Idempotent.
# Creates the on-premises source for the demo: one database, one table, one row.
# Every statement is guarded with IF ... IS NULL / NOT EXISTS, so re-running changes nothing.
. "$PSScriptRoot\common.ps1"
Write-Host '== 02 Local =='

# Invoke-LocalSql (common.ps1) connects to $Cfg.LocalSqlInstance and logs each statement and its result.
# Windows authentication (current user) is used because no credentials are given.
# TrustServerCertificate: a local instance usually has a self-signed certificate.
Write-LogValue 'local instance' $Cfg.LocalSqlInstance
Write-LogValue 'local database' $Cfg.LocalDbName

# 1. Database: created only when DB_ID() finds no database with that name.
Invoke-LocalSql -Query "IF DB_ID('$($Cfg.LocalDbName)') IS NULL CREATE DATABASE [$($Cfg.LocalDbName)];"

# 2. Table and sample row, inside the new database.
# The here-string (@" ... "@) lets the SQL span several lines.
#   - OBJECT_ID() returns NULL when the table does not exist yet, so it is created once.
#   - The row is inserted only if CustomerId 1 is not there, so no duplicate-key error on re-run.
# This is the row the Fabric pipeline copies later (step 04) and step 05 enriches.
Invoke-LocalSql -Database $Cfg.LocalDbName -Query @"
IF OBJECT_ID('dbo.Customer') IS NULL
    CREATE TABLE dbo.Customer (CustomerId int NOT NULL PRIMARY KEY, LastName nvarchar(100) NOT NULL, Initials nvarchar(10) NULL);
IF NOT EXISTS (SELECT 1 FROM dbo.Customer WHERE CustomerId = 1)
    INSERT dbo.Customer VALUES (1, N'Pietersen', N'B');
"@

# 3. Read-only SQL login for the Fabric gateway connection.
# The gateway cannot always impersonate a Windows user ("failed to impersonate the user"), so the
# Fabric connection uses SQL authentication instead. Needs mixed-mode authentication on the instance
# (checked below). The password is generated once, kept in .secrets\state.json and re-applied on each run,
# so the login on the server and the saved password cannot drift apart.
# The login is a server-level object: 99-Cleanup drops it even without -DropLocal.
$state = Get-State
if (-not $state.localReaderPwd) { Set-State 'localReaderPwd' ([Guid]::NewGuid().ToString('N') + 'aA1!'); $state = Get-State }
Write-LogValue 'fabric_local_user password' $state.localReaderPwd
$mode = Invoke-LocalSql -Query "SELECT CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS WindowsOnly"
if ($mode.WindowsOnly -eq 1) { throw 'Local SQL Server allows Windows authentication only. Enable mixed mode (SSMS: server properties > Security) and restart the service.' }
Invoke-LocalSql -Query @"
IF SUSER_ID('fabric_local_user') IS NULL
    CREATE LOGIN [fabric_local_user] WITH PASSWORD = N'$($state.localReaderPwd)', CHECK_POLICY = OFF;
ELSE
    ALTER LOGIN [fabric_local_user] WITH PASSWORD = N'$($state.localReaderPwd)';
"@
Invoke-LocalSql -Database $Cfg.LocalDbName -Query @"
IF USER_ID('fabric_local_user') IS NULL CREATE USER [fabric_local_user] FOR LOGIN [fabric_local_user];
ALTER ROLE db_datareader ADD MEMBER [fabric_local_user];
"@

# 4. Show the result so you can see the step worked.
Invoke-LocalSql -Database $Cfg.LocalDbName -Query 'SELECT * FROM dbo.Customer' | Format-Table
