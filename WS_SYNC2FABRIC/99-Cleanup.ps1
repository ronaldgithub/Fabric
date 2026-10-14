# Cleanup: removes everything the demo created in Azure and Fabric. Add -DropLocal to drop the local db1 too.
# Safe to run repeatedly: every delete is guarded by an existence check, so a second run does nothing.
# Without -DropLocal the local SQL Server is left alone (it is not a cloud cost and step 02 is idempotent).
param([switch]$DropLocal)
. "$PSScriptRoot\common.ps1"
Write-Host '== 99 Cleanup =='
$state = Get-State
Write-LogValue 'DropLocal' $DropLocal.IsPresent
Write-LogValue 'state before cleanup' $state

# --- Fabric ---
# Deleting the workspace also deletes everything in it: warehouse db1, the pipeline and the staging data.
# The workspace is found by name (not from the state file), so cleanup also works after the state file is lost.
$ws = Get-FabricItemByName '/workspaces' $Cfg.WorkspaceName
if ($ws) { Invoke-Fabric DELETE "/workspaces/$($ws.id)" | Out-Null; Write-Host 'Fabric workspace deleted.' }
# The connection to Azure SQL lives outside the workspace (tenant level), so it is deleted separately.
# A failure here (already gone, no permission) only warns, so the Azure cleanup below still runs.
if ($state.azureConnId) { try { Invoke-Fabric DELETE "/connections/$($state.azureConnId)" | Out-Null } catch { Write-Warning $_ } }

# --- Azure ---
# Deleting the resource group removes the SQL server, the database and the firewall rules in one go.
# --no-wait returns immediately; Azure finishes the deletion in the background (a few minutes).
if ((az group exists -n $Cfg.ResourceGroup) -eq 'true') {
    az group delete -n $Cfg.ResourceGroup --yes --no-wait
    Write-Host 'Resource group deletion started.'
}

# --- Local SQL Server (only with -DropLocal) ---
# SINGLE_USER WITH ROLLBACK IMMEDIATE disconnects other sessions first, otherwise DROP DATABASE
# fails with "database is in use". This permanently deletes the local database and its data.
# The SQL login for the Fabric gateway connection is a server-level object and would survive a dropped
# database, so it is removed in every cleanup (the db user goes with the database when -DropLocal is used).
Invoke-LocalSql -Query "IF SUSER_ID('fabric_local_user') IS NOT NULL DROP LOGIN [fabric_local_user];"
if ($DropLocal) {
    Invoke-LocalSql `
        -Query "IF DB_ID('$($Cfg.LocalDbName)') IS NOT NULL BEGIN ALTER DATABASE [$($Cfg.LocalDbName)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$($Cfg.LocalDbName)]; END"
    Write-Host 'Local database dropped.'
}

# Forget the saved ids and generated passwords: they no longer point to anything.
# This is last on purpose, so a failed run keeps the state and can be retried.
if (Test-Path $StateFile) { Remove-Item $StateFile }
