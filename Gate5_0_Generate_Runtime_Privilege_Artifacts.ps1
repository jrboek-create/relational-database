Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = "C:\Directus\relational-repository"
$Container = "relational-repository-database-1"
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $Root ("sql\gate5\runtime_privileges_" + $Stamp)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
function Run-Psql {
    param([string]$Sql)
    $Old = $ErrorActionPreference
    $Raw = @()
    try {
        $ErrorActionPreference = "Continue"
        $Raw = @($Sql | & docker.exe exec -i $Container sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -q -t -A -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Old
    }
    $Lines = @()
    foreach ($Item in $Raw) {
        foreach ($Line in ([string]$Item -split "`r?`n")) {
            $Value = $Line.Trim()
            if ($Value.Length -gt 0) { $Lines += $Value }
        }
    }
    if ($Code -ne 0) { throw ("psql failed: " + ($Lines -join " | ")) }
    return $Lines
}
function Write-Ascii {
    param([string]$Path,[string[]]$Lines)
    [System.IO.File]::WriteAllLines($Path,$Lines,[System.Text.Encoding]::ASCII)
}
$CountSql = @'
SELECT 'directus_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'directus_sequences=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind='S' AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'core_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='core' AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'reporting_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='reporting' AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'staging_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='staging' AND c.relkind IN ('r','p');
SELECT 'phase2_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='phase2_staging' AND c.relkind IN ('r','p');
SELECT 'runtime_role_valid=' || count(*) FROM pg_roles WHERE rolname='directus_runtime' AND rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'runtime_owner_membership=' || count(*) FROM pg_auth_members m JOIN pg_roles mr ON mr.oid=m.member JOIN pg_roles gr ON gr.oid=m.roleid WHERE mr.rolname='directus_runtime' AND gr.rolname='air_repository_owner';
SELECT 'runtime_owned_objects=' || count(*) FROM pg_class WHERE pg_get_userbyid(relowner)='directus_runtime';
SELECT 'database_bootstrap_owner=' || count(*) FROM pg_database WHERE datname='directus_repository' AND pg_get_userbyid(datdba)='directus_repository';
SELECT 'default_acl_entries=' || count(*) FROM pg_default_acl d JOIN pg_roles r ON r.oid=d.defaclrole WHERE r.rolname='air_repository_owner';
SELECT 'public_function_execute=' || CASE WHEN has_function_privilege('public','staging.assert_row_count(regclass,bigint)','EXECUTE') THEN 1 ELSE 0 END;
'@
$Counts = @(Run-Psql $CountSql)
$Expected = @(
    "directus_tables=33",
    "directus_sequences=8",
    "core_tables=15",
    "reporting_tables=2",
    "staging_tables=39",
    "phase2_tables=7",
    "runtime_role_valid=1",
    "runtime_owner_membership=0",
    "runtime_owned_objects=0",
    "database_bootstrap_owner=1",
    "default_acl_entries=0"
)
foreach ($Item in $Expected) {
    if ($Counts -notcontains $Item) {
        throw ("Expected result missing: " + $Item + ". Observed: " + ($Counts -join ", "))
    }
}
$PublicFunctionExecute = (($Counts | Where-Object { $_ -like "public_function_execute=*" }) -eq "public_function_execute=1")
$DirectusTablesSql = @'
SELECT format('%I.%I',n.nspname,c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='air_repository_owner' ORDER BY c.relname;
'@
$DirectusSequencesSql = @'
SELECT format('%I.%I',n.nspname,c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind='S' AND pg_get_userbyid(c.relowner)='air_repository_owner' ORDER BY c.relname;
'@
$DirectusTables = @(Run-Psql $DirectusTablesSql)
$DirectusSequences = @(Run-Psql $DirectusSequencesSql)
if ($DirectusTables.Count -ne 33) { throw "Expected 33 Directus tables." }
if ($DirectusSequences.Count -ne 8) { throw "Expected 8 Directus sequences." }
$ForwardBody = @(
    "REVOKE ALL PRIVILEGES ON DATABASE directus_repository FROM directus_runtime;"
    "GRANT CONNECT ON DATABASE directus_repository TO directus_runtime;"
    "REVOKE ALL PRIVILEGES ON SCHEMA public, core, reporting, staging, phase2_staging FROM directus_runtime;"
    "GRANT USAGE ON SCHEMA public, core, reporting TO directus_runtime;"
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA core, reporting, staging, phase2_staging FROM directus_runtime;"
    "GRANT SELECT ON ALL TABLES IN SCHEMA core, reporting TO directus_runtime;"
    "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA core, reporting, staging, phase2_staging FROM directus_runtime;"
    "REVOKE EXECUTE ON FUNCTION staging.assert_row_count(regclass,bigint) FROM directus_runtime;"
    "REVOKE EXECUTE ON FUNCTION staging.assert_row_count(regclass,bigint) FROM PUBLIC;"
)
foreach ($Table in $DirectusTables) {
    $ForwardBody += "REVOKE ALL PRIVILEGES ON TABLE $Table FROM directus_runtime;"
    $ForwardBody += "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE $Table TO directus_runtime;"
}
foreach ($Sequence in $DirectusSequences) {
    $ForwardBody += "REVOKE ALL PRIVILEGES ON SEQUENCE $Sequence FROM directus_runtime;"
    $ForwardBody += "GRANT USAGE, SELECT ON SEQUENCE $Sequence TO directus_runtime;"
}
$ReverseBody = @(
    "REVOKE ALL PRIVILEGES ON DATABASE directus_repository FROM directus_runtime;"
    "REVOKE ALL PRIVILEGES ON SCHEMA public, core, reporting, staging, phase2_staging FROM directus_runtime;"
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA core, reporting, staging, phase2_staging FROM directus_runtime;"
    "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA core, reporting, staging, phase2_staging FROM directus_runtime;"
    "REVOKE EXECUTE ON FUNCTION staging.assert_row_count(regclass,bigint) FROM directus_runtime;"
)
foreach ($Table in $DirectusTables) {
    $ReverseBody += "REVOKE ALL PRIVILEGES ON TABLE $Table FROM directus_runtime;"
}
foreach ($Sequence in $DirectusSequences) {
    $ReverseBody += "REVOKE ALL PRIVILEGES ON SEQUENCE $Sequence FROM directus_runtime;"
}
if ($PublicFunctionExecute) {
    $ReverseBody += "GRANT EXECUTE ON FUNCTION staging.assert_row_count(regclass,bigint) TO PUBLIC;"
}
$Header = @(
    "\set ON_ERROR_STOP on"
    "BEGIN;"
    "SET LOCAL lock_timeout = '5s';"
    "SET LOCAL statement_timeout = '120s';"
)
$ForwardPath = Join-Path $OutDir "gate5_0_runtime_privileges_forward.sql"
$RehearsalPath = Join-Path $OutDir "gate5_0_runtime_privileges_rehearsal.sql"
$ReversePath = Join-Path $OutDir "gate5_0_runtime_privileges_reverse.sql"
$InventoryPath = Join-Path $OutDir "gate5_0_runtime_privileges_before.csv"
$ManifestPath = Join-Path $OutDir "gate5_0_runtime_privileges_manifest.csv"
Write-Ascii $ForwardPath (@($Header)+@($ForwardBody)+@("COMMIT;"))
Write-Ascii $RehearsalPath (@($Header)+@($ForwardBody)+@("ROLLBACK;"))
Write-Ascii $ReversePath (@($Header)+@($ReverseBody)+@("COMMIT;"))
$Inventory = foreach ($Line in $Counts) {
    $Parts = $Line -split "=",2
    [pscustomobject]@{Control=$Parts[0];Value=$Parts[1]}
}
$Inventory | Export-Csv -LiteralPath $InventoryPath -NoTypeInformation -Encoding ASCII
$Files = @($ForwardPath,$RehearsalPath,$ReversePath,$InventoryPath)
$Forbidden = "(?i)(REASSIGN\s+OWNED|tiger|tiger_data|topology|spatial_ref_sys|ALTER\s+DEFAULT\s+PRIVILEGES)"
foreach ($File in @($ForwardPath,$RehearsalPath,$ReversePath)) {
    $Text = [System.IO.File]::ReadAllText($File)
    if ($Text -match $Forbidden) { throw ("Prohibited scope found in " + $File) }
}
$Manifest = foreach ($File in $Files) {
    $Item = Get-Item -LiteralPath $File
    [pscustomobject]@{File=$Item.Name;Bytes=$Item.Length;SHA256=(Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash}
}
$Manifest | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding ASCII
Write-Host "GATE 5.0 RUNTIME PRIVILEGE ARTIFACT GENERATION - PASS" -ForegroundColor Green
Write-Host ("ArtifactDirectory=" + $OutDir)
foreach ($Line in $Counts) { Write-Host $Line }
Write-Host "DefaultPrivilegesChanged=NO"
Write-Host "GeneratedSQLExecuted=NO"
$Manifest | Format-Table File,Bytes,SHA256 -AutoSize
Write-Host "STOP. DO NOT EXECUTE THE GENERATED SQL FILES." -ForegroundColor Yellow