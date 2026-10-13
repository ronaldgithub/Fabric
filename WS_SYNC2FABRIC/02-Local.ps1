# Step 2: local Win10 SQL Server db1.dbo.Customer with (1, Pietersen, B). Idempotent.
. "$PSScriptRoot\common.ps1"
Write-Host '== 02 Local =='

$p = @{ ServerInstance = $Cfg.LocalSqlInstance; TrustServerCertificate = $true }
Invoke-Sqlcmd @p -Query "IF DB_ID('$($Cfg.LocalDbName)') IS NULL CREATE DATABASE [$($Cfg.LocalDbName)];"
Invoke-Sqlcmd @p -Database $Cfg.LocalDbName -Query @"
IF OBJECT_ID('dbo.Customer') IS NULL
    CREATE TABLE dbo.Customer (CustomerId int NOT NULL PRIMARY KEY, LastName nvarchar(100) NOT NULL, Initials nvarchar(10) NULL);
IF NOT EXISTS (SELECT 1 FROM dbo.Customer WHERE CustomerId = 1)
    INSERT dbo.Customer VALUES (1, N'Pietersen', N'B');
"@
Invoke-Sqlcmd @p -Database $Cfg.LocalDbName -Query 'SELECT * FROM dbo.Customer' | Format-Table
