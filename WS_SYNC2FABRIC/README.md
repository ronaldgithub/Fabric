# Fabric demo

Azure SQL `db1.dbo.Customer` (1, Jansen, A) and local SQL `db1.dbo.Customer` (1, Pietersen, B) are loaded into Warehouse `db1` (`stg`; Azure by script, local by a gateway pipeline), enriched, and written to `dwh.Customers` (2 rows).

## Prerequisites
- PowerShell 7, Azure CLI, `SqlServer` module.
- `az login` for the Azure account, plus `az login --tenant <fabric tenant> --allow-no-subscriptions` for the Fabric account (if different).
- An existing Fabric capacity (trial or F SKU).
- Optional, for the local source: an on-premises data gateway and a gateway SQL Server connection created once in the Fabric portal (GUID goes in `LocalConnectionId`). Without it step 04 skips the local copy and verify expects 1 row.

## Use
```powershell
Copy-Item config.example.ps1 config.ps1   # edit: subscription, capacity name, ...
./Run-All.ps1            # build everything
./Run-All.ps1 -Cleanup   # build, verify, then delete everything
./99-Cleanup.ps1 -DropLocal   # cleanup only (also drops local db1)
```
Or run steps `00`..`06` one by one.

| Step | What |
|---|---|
| 00 | Check login, tools, capacity |
| 01 | Resource group, SQL server, db1, dbo.Customer |
| 02 | Local db1.dbo.Customer |
| 03 | Workspace, Azure SQL connection, warehouse |
| 04 | Staging tables, pipeline copying both sources |
| 05 | Enrichment into dwh.Customers |
| 06 | Verify |
| 99 | Cleanup |

## Cost
Serverless GP Azure SQL (0.5 vCore min, auto-pause) for the duration of the run, a few cents. Fabric uses your existing capacity. Always run cleanup.

## Security
`config.ps1` and `.secrets/` are git-ignored; auth uses Entra tokens, generated passwords stay in `.secrets/`.
