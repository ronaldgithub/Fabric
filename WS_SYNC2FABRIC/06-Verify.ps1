# Step 6: show dwh.Customers; expect 2 rows when both sources are loaded.
. "$PSScriptRoot\common.ps1"
Write-Host '== 06 Verify =='
$state = Get-State
$rows = Invoke-Sql $state.warehouseServer $Cfg.WarehouseName 'SELECT * FROM dwh.Customers ORDER BY CustomerKey' $Cfg.FabricTenant
$rows | Format-Table
$expected = if ($Cfg.LocalConnectionId) { 2 } else { 1 }
if (@($rows).Count -ne $expected) { throw "Expected $expected rows, got $(@($rows).Count)" }
Write-Host 'Verify OK'
