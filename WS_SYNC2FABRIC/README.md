# Fabric demo

Azure SQL `db1.dbo.Customer` (1, Jansen, A) and local SQL `db1.dbo.Customer` (1, Pietersen, B) are loaded into Warehouse `db1` (`stg`; Azure by script, local by a gateway pipeline), enriched, and written to `dwh.Customers` (2 rows).

## Prerequisites
- PowerShell 7, Azure CLI, `SqlServer` module.
- `az login` for the Azure account, plus `az login --tenant <fabric tenant> --allow-no-subscriptions` for the Fabric account (if different).
- An existing Fabric capacity (trial or F SKU).
- Optional, for the local source (see "Local source via gateway" below): an on-premises data gateway and a gateway SQL Server connection created once in the Fabric portal (GUID goes in `LocalConnectionId`). Without it step 04 skips the local copy and verify expects 1 row.

## Local source via gateway (one-time, manual)
Verified working: the local row travels through a Fabric pipeline (gateway, staging, warehouse).
1. Install the *On-premises data gateway (standard mode)* on this PC and register it with the Fabric tenant account (e.g. `gw-fabricdemo`). Fabric must show Ready.
2. Run `02-Local.ps1`. It creates the read-only SQL login `fabric_local_user` (needs mixed-mode authentication on the instance) and saves its password as `localReaderPwd` in `.secrets/state.json`.
3. Fabric portal > Manage connections and gateways > Connections > New > On-premises: gateway `gw-fabricdemo`, SQL Server, server `localhost`, database `db1`, authentication Basic, user `fabric_local_user`, password from `.secrets/state.json`.
4. Put the connection GUID in `LocalConnectionId` in `config.ps1`.

Notes from the first run: Windows authentication failed ("failed to impersonate the user"), so SQL authentication is used. The warehouse COPY cannot read a SQL Server source directly, so the pipeline copy runs with staging enabled. `99-Cleanup.ps1` drops the SQL login but not the gateway or the Fabric connection `conn-local-sql` (created by hand, delete it in the portal).

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
| 02 | Local db1.dbo.Customer, read-only SQL login for the gateway |
| 03 | Workspace, Azure SQL connection, warehouse |
| 04 | Staging tables, Azure row by script, local row by pipeline via gateway |
| 05 | Enrichment into dwh.Customers |
| 06 | Verify |
| 99 | Cleanup |

## Cost
Serverless GP Azure SQL (0.5 vCore min, auto-pause) for the duration of the run, a few cents. Fabric uses your existing capacity. Always run cleanup.

## Logging
Every run writes one very verbose log to `logs\run-<yyyyMMdd-HHmmss>.log` (`Run-All.ps1` shares one file for all steps; a step started alone gets its own). Line format:

`time | KIND | file:line | message` (multi-line values continue on indented lines that start with `|`)

Kinds: `STEP` start/end, `CFG` full config, `AZ` every az command with stdout/stderr/exit code, `SQL` every statement with server, database and returned rows, `REST` every Fabric call with request, response and polling, `STATE` state-file reads/writes, `VALUE` values used, `DECIDE` create-or-skip decisions, `WARN`, `ERROR`. Follow a run live with `Get-Content logs\run-*.log -Wait -Tail 20`.

The log deliberately contains secrets (passwords, raw access tokens). It is git-ignored; clean it up and never share it.

## Security
`config.ps1` and `.secrets/` are git-ignored; auth uses Entra tokens, generated passwords stay in `.secrets/`. `logs/` is git-ignored too and contains secrets by design (see Logging).
