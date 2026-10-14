# Step 6: show dwh.Customers; expect 2 rows when both sources are loaded.
# Read-only check: nothing is changed. Fails (non-zero exit) when the row count is wrong,
# so Run-All.ps1 stops here instead of reporting a false success.
. "$PSScriptRoot\common.ps1"
Write-Host '== 06 Verify =='
# Step 03 stores the warehouse SQL endpoint in the state file.
$state = Get-State
if (-not $state.warehouseServer) { throw 'Run 03-Fabric.ps1 first.' }
# Read the enriched table built in step 05; ORDER BY gives a stable order for the printed result.
$rows = Invoke-Sql $state.warehouseServer $Cfg.WarehouseName 'SELECT * FROM dwh.Customers ORDER BY CustomerKey' $Cfg.FabricTenant
$rows | Format-Table
# One row per source system: Azure SQL always, plus the local SQL Server when step 04 could
# copy it (that needs LocalConnectionId; without it only the Azure row is loaded).
$expected = if ($Cfg.LocalConnectionId) { 2 } else { 1 }
# @(...) makes .Count work for 0 rows (null) and 1 row (a single object) as well as for many.
Write-Log -Kind DECIDE "LocalConnectionId='$($Cfg.LocalConnectionId)' -> expected rows=$expected, actual rows=$(@($rows).Count)"
if (@($rows).Count -ne $expected) { throw "Expected $expected rows, got $(@($rows).Count)" }
Write-Host 'Verify OK'
