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

## Known unverified areas
Local copy pipeline (`pipeline-content.json` in 04-Load.ps1): never run yet; a warehouse COPY from a non-Fabric source may need staging enabled. The Azure rows are loaded by script because a warehouse sink rejected Azure SQL as direct source.
