# Cleanup: removes everything the demo created in Azure and Fabric. Add -DropLocal to drop the local db1 too.
param([switch]$DropLocal)
. "$PSScriptRoot\common.ps1"
Write-Host '== 99 Cleanup =='
$state = Get-State

$ws = Get-FabricItemByName '/workspaces' $Cfg.WorkspaceName
if ($ws) { Invoke-Fabric DELETE "/workspaces/$($ws.id)" | Out-Null; Write-Host 'Fabric workspace deleted.' }
if ($state.azureConnId) { try { Invoke-Fabric DELETE "/connections/$($state.azureConnId)" | Out-Null } catch { Write-Warning $_ } }

if ((az group exists -n $Cfg.ResourceGroup) -eq 'true') {
    az group delete -n $Cfg.ResourceGroup --yes --no-wait
    Write-Host 'Resource group deletion started.'
}

if ($DropLocal) {
    Invoke-Sqlcmd -ServerInstance $Cfg.LocalSqlInstance -TrustServerCertificate `
        -Query "IF DB_ID('$($Cfg.LocalDbName)') IS NOT NULL BEGIN ALTER DATABASE [$($Cfg.LocalDbName)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$($Cfg.LocalDbName)]; END"
    Write-Host 'Local database dropped.'
}
if (Test-Path $StateFile) { Remove-Item $StateFile }
