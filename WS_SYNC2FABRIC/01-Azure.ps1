# Step 1: Resource group, Azure SQL server + db1 + dbo.Customer (1, Jansen, A).
# Idempotent: every resource is created only if missing, so re-running is safe.

# Load shared config ($Cfg) and helpers (Get-SqlServerName, Invoke-Sql, Get-State/Set-State)
. "$PSScriptRoot\common.ps1"
Write-Host '== 01 Azure =='

# Server name comes from common.ps1 (globally unique, stable across re-runs).
$server = Get-SqlServerName
$fqdn   = "$server.database.windows.net"
# UPN + object id of the signed-in user; both are needed to make that user the Entra admin below.
$me     = az ad signed-in-user show --query "{upn:userPrincipalName,oid:id}" -o json | ConvertFrom-Json
Write-LogValue 'server' $server
Write-LogValue 'fqdn' $fqdn
Write-LogValue 'signed-in user (Entra admin to be)' $me

# 'group create' is an upsert: it succeeds silently when the group already exists.
az group create -n $Cfg.ResourceGroup -l $Cfg.Location -o none

# Entra admin = you. SQL auth stays enabled only so a read-only login can be used by Fabric (other tenant).
# Create the server only when it does not exist yet; the JMESPath query returns the number of matches ('0' = none).
$exists = az sql server list -g $Cfg.ResourceGroup --query "[?name=='$server'] | length(@)" -o tsv
Write-Log -Kind DECIDE "sql server '$server' matches in $($Cfg.ResourceGroup): $exists -> $(if ($exists -eq '0') { 'create it' } else { 'exists, skip create' })"
if ($exists -eq '0') {
    # The server requires an admin login even though we sign in via Entra; the password is random,
    # meets the complexity rules (the 'aA1!' suffix) and is never printed.
    $adminPwd = [Guid]::NewGuid().ToString('N') + 'aA1!'     # throw-away, kept only in .secrets
    az sql server create -g $Cfg.ResourceGroup -n $server -l $Cfg.Location `
        -u demoadmin -p $adminPwd -o none
    Set-State 'sqlAdminPwd' $adminPwd
}
# Make the signed-in user Entra admin; this is what Invoke-Sql uses to connect with an Entra token.
az sql server ad-admin create -g $Cfg.ResourceGroup -s $server -u $me.upn -i $me.oid -o none

# --- Firewall ---
# Allow this machine's current public IP so the script can run T-SQL against the server.
$ip = (Invoke-RestMethod 'https://api.ipify.org').Trim()
Write-LogValue 'public client IP (firewall rule demo-client)' $ip
az sql server firewall-rule create -g $Cfg.ResourceGroup -s $server -n demo-client --start-ip-address $ip --end-ip-address $ip -o none
# The special range 0.0.0.0-0.0.0.0 means "allow Azure services"; this lets the Fabric pipeline reach the server.
az sql server firewall-rule create -g $Cfg.ResourceGroup -s $server -n AllowAzure --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 -o none

# --- Database ---
# Cheapest option: serverless GP with auto-pause (1 h), 0.5 vCore min. Pauses itself when idle.
# Local backup redundancy avoids the extra cost of geo-redundant backups (fine for a throw-away demo).
$db = az sql db list -g $Cfg.ResourceGroup -s $server --query "[?name=='$($Cfg.AzureDbName)'] | length(@)" -o tsv
Write-Log -Kind DECIDE "database '$($Cfg.AzureDbName)' matches: $db -> $(if ($db -eq '0') { 'create it (serverless GP, 0.5-1 vCore, auto-pause 60 min)' } else { 'exists, skip create' })"
if ($db -eq '0') {
    az sql db create -g $Cfg.ResourceGroup -s $server -n $Cfg.AzureDbName `
        --edition GeneralPurpose --compute-model Serverless --family Gen5 --capacity 1 --min-capacity 0.5 `
        --auto-pause-delay 60 --backup-storage-redundancy Local -o none
}

# Sample data: create the table and the single seed row only if they are not there yet.
# The first connection may take a while when the serverless database is paused and has to resume.
Invoke-Sql $fqdn $Cfg.AzureDbName @"
IF OBJECT_ID('dbo.Customer') IS NULL
    CREATE TABLE dbo.Customer (CustomerId int NOT NULL PRIMARY KEY, LastName nvarchar(100) NOT NULL, Initials nvarchar(10) NULL);
IF NOT EXISTS (SELECT 1 FROM dbo.Customer WHERE CustomerId = 1)
    INSERT dbo.Customer VALUES (1, N'Jansen', N'A');
"@

# Read-only SQL user for the Fabric pipeline connection.
# Fabric is in a different tenant and cannot use our Entra identity, so it signs in with SQL auth.
# The password is generated once and reused on re-runs, so the existing Fabric connection keeps working.
$state = Get-State
Write-Log -Kind DECIDE "readerPwd in state file: $(if ($state.readerPwd) { 'yes, reuse' } else { 'no, generate new' })"
if (-not $state.readerPwd) { Set-State 'readerPwd' ([Guid]::NewGuid().ToString('N') + 'aA1!'); $state = Get-State }
Write-LogValue 'fabric_reader password' $state.readerPwd
# A contained database user (no server login needed), limited to reading data.
Invoke-Sql $fqdn $Cfg.AzureDbName @"
IF USER_ID('fabric_reader') IS NULL CREATE USER fabric_reader WITH PASSWORD = '$($state.readerPwd)';
ALTER ROLE db_datareader ADD MEMBER fabric_reader;
"@

# Save the server name for later steps (04-Load etc.).
Set-State 'sqlFqdn' $fqdn
Write-Host "Azure SQL ready: $fqdn / $($Cfg.AzureDbName)"
