# Fabric_Test1

Repeatable PowerShell demo: Azure SQL + local SQL Server -> (Fabric pipeline) -> Fabric Warehouse `db1` -> enriched `dwh.Customers`.
Mirroring was dropped: Azure (opendata.nl tenant) and Fabric (onmicrosoft.com tenant) are different tenants, which mirroring does not support.

## Conventions
- PowerShell 7 (`pwsh`). One numbered script per step (`00`..`06`, `99-Cleanup`), each dot-sources `common.ps1`.
- Every step is idempotent and safe to re-run. `Run-All.ps1 -Cleanup` must always leave nothing behind.
- Use `az` CLI + Fabric REST (`Invoke-Fabric`) and `Invoke-Sqlcmd` with Entra tokens. No Az module (old version installed).
- Two logins: Azure subscription account (opendata.nl) and Fabric tenant-level account (`FabricTenant` in config). The Fabric token is fetched with `az account get-access-token --subscription <tenantId>` (not `--tenant`, which picks the wrong cached account).
- Region: West/North Europe refuse new SQL servers on this subscription; `germanywestcentral` works.
- Keep it simple and low cost: serverless GP Azure SQL, existing Fabric trial capacity, delete RG + workspace after each run.

## Security
- Never commit `config.ps1` or `.secrets/` (both in `.gitignore`). `config.example.ps1` holds no secrets.
- Generated passwords live only in `.secrets/state.json`. Never print them or put them in scripts.
- Exception: `logs/run-*.log` contain passwords and raw tokens on purpose (verbose DBA log, see README "Logging"). `logs/` is git-ignored; never commit, paste or publish them. Artifacts built from a log (e.g. `docs/architecture_detail.html`) must have secrets, tokens and real tenant/subscription ids replaced by placeholders.

## Local source via gateway (verified 2026-10-14)
- The local copy pipeline (`pipeline-content.json` in 04-Load.ps1) runs successfully: gateway connection `conn-local-sql` -> Copy with `enableStaging = $true` -> `stg.Customer_Local` (about 60 s for one row). Staging is required: the warehouse COPY command rejects a SqlServer source ("doesn't support 'Source connector type' as 'SqlServer'").
- The gateway cannot impersonate the Windows user here ("failed to impersonate the user"), so the connection uses SQL auth with login `fabric_local_user`, created by 02-Local.ps1 (password `localReaderPwd` in `.secrets/state.json`). 99-Cleanup always drops that login; `-DropLocal` also drops the database.
- Manual one-time setup, not scripted: install the gateway and create the connection in the Fabric portal, then put its GUID in `LocalConnectionId`. 99-Cleanup does not remove the gateway or the connection `conn-local-sql`. See README.
- The Azure rows are still loaded by script because a warehouse sink rejected Azure SQL as direct source.

## Known issues
- `common.ps1` fetches a fresh token for every Fabric/SQL call (about 18 s per run) and `az sql server ad-admin create` runs on every run (17 s). Not cached or guarded yet.
- A paused serverless Azure SQL database needs up to a minute to resume; `Invoke-Sql` uses a 120 s connection timeout and retries twice.
