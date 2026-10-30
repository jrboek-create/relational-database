Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$SelfPath = $MyInvocation.MyCommand.Path
$SelfBadBytes = @([System.IO.File]::ReadAllBytes($SelfPath) | Where-Object { $_ -gt 127 })
if ($SelfBadBytes.Count -ne 0) { throw "STOP: Script contains $($SelfBadBytes.Count) non-ASCII bytes." }
$Root = "C:\Directus\relational-repository"
$Container = "relational-repository-database-1"
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Gate5Root = Join-Path $Root "sql\gate5"
$BuildDir = Join-Path $Gate5Root ("ownership_" + $Stamp + "_BUILDING")
$FinalDir = Join-Path $Gate5Root ("ownership_" + $Stamp)
$FailedDir = Join-Path $Gate5Root ("ownership_" + $Stamp + "_FAILED")
function Write-AsciiFile {
param([string]$Path,[string[]]$Lines)
[System.IO.File]::WriteAllLines($Path,$Lines,[System.Text.Encoding]::ASCII)
}
function Invoke-RepositoryPsql {
param([string]$Sql)
$OldPreference = $ErrorActionPreference
$Raw = @()
$ExitCode = -1
try {
$ErrorActionPreference = "Continue"
$Raw = @($Sql | & docker.exe exec -i $Container sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -q -t -A -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
$ExitCode = $LASTEXITCODE
}
finally {
$ErrorActionPreference = $OldPreference
}
$Lines = @()
foreach ($Item in $Raw) {
foreach ($Line in ([string]$Item -split "`r?`n")) {
$Text = $Line.Trim()
if ($Text.Length -gt 0) { $Lines += $Text }
}
}
if ($ExitCode -ne 0) { throw ("PostgreSQL query failed with exit code " + $ExitCode + ":`r`n" + ($Lines -join "`r`n")) }
return $Lines
}
function Assert-ExactCount {
param([string]$Name,[int]$Expected,[int]$Actual)
if ($Actual -ne $Expected) { throw ($Name + " expected " + $Expected + " but found " + $Actual + ".") }
}
try {
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw ("Repository root not found: " + $Root) }
if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) { throw "docker.exe was not found in PATH." }
New-Item -ItemType Directory -Path $Gate5Root -Force | Out-Null
New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
$CountSql = @(
"SELECT 'schemas=' || count(*) FROM pg_namespace WHERE nspname IN ('core','reporting','staging','phase2_staging') AND pg_get_userbyid(nspowner)='directus_repository';"
"SELECT 'tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='directus_repository' AND NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e');"
"SELECT 'sequences=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='S' AND pg_get_userbyid(c.relowner)='directus_repository' AND NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e');"
"SELECT 'functions=' || count(*) FROM pg_proc p WHERE p.oid=to_regprocedure('staging.assert_row_count(regclass,bigint)') AND pg_get_userbyid(p.proowner)='directus_repository' AND NOT p.prosecdef AND NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e');"
"SELECT 'database=' || count(*) FROM pg_database WHERE datname='directus_repository' AND pg_get_userbyid(datdba)='directus_repository';"
"SELECT 'owner_role_valid=' || count(*) FROM pg_roles WHERE rolname='air_repository_owner' AND NOT rolsuper AND NOT rolcanlogin AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;"
"SELECT 'runtime_role_valid=' || count(*) FROM pg_roles WHERE rolname='directus_runtime' AND NOT rolsuper AND rolcanlogin AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;"
"SELECT 'runtime_owner_membership=' || count(*) FROM pg_auth_members m JOIN pg_roles mr ON mr.oid=m.member JOIN pg_roles gr ON gr.oid=m.roleid WHERE mr.rolname='directus_runtime' AND gr.rolname='air_repository_owner';"
"SELECT 'unexpected_relation_kinds=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind NOT IN ('r','p','S','i');"
) -join "`r`n"
$Counts = @(Invoke-RepositoryPsql $CountSql)
$RequiredCounts = @("schemas=4","tables=96","sequences=12","functions=1","database=1","owner_role_valid=1","runtime_role_valid=1","runtime_owner_membership=0","unexpected_relation_kinds=0")
Assert-ExactCount "Catalog count rows" 9 $Counts.Count
foreach ($Required in $RequiredCounts) {
if ($Counts -notcontains $Required) { throw ("Expected result missing: " + $Required + ". Observed: " + ($Counts -join ", ")) }
}
$SchemaSql = "SELECT format('ALTER SCHEMA %I OWNER TO air_repository_owner;',nspname) FROM pg_namespace WHERE nspname IN ('core','reporting','staging','phase2_staging') AND pg_get_userbyid(nspowner)='directus_repository' ORDER BY nspname;"
$Schemas = @(Invoke-RepositoryPsql $SchemaSql)
Assert-ExactCount "Schema statements" 4 $Schemas.Count
$TableSql = "SELECT format('ALTER TABLE %I.%I OWNER TO air_repository_owner;',n.nspname,c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='directus_repository' AND NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e') ORDER BY n.nspname,c.relname;"
$Tables = @(Invoke-RepositoryPsql $TableSql)
Assert-ExactCount "Table statements" 96 $Tables.Count
$SequenceSql = "SELECT format('ALTER SEQUENCE %I.%I OWNER TO air_repository_owner;',n.nspname,c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='S' AND pg_get_userbyid(c.relowner)='directus_repository' AND NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e') ORDER BY n.nspname,c.relname;"
$Sequences = @(Invoke-RepositoryPsql $SequenceSql)
Assert-ExactCount "Sequence statements" 12 $Sequences.Count
$FunctionSql = "SELECT format('ALTER FUNCTION %I.%I(%s) OWNER TO air_repository_owner;',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.oid=to_regprocedure('staging.assert_row_count(regclass,bigint)') AND pg_get_userbyid(p.proowner)='directus_repository' AND NOT p.prosecdef AND NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e');"
$Functions = @(Invoke-RepositoryPsql $FunctionSql)
Assert-ExactCount "Function statements" 1 $Functions.Count
$ForwardStatements = @($Schemas) + @($Tables) + @($Sequences) + @($Functions)
Assert-ExactCount "Forward statements" 113 $ForwardStatements.Count
$ReverseFunctions = @($Functions | ForEach-Object { $_ -replace "air_repository_owner;","directus_repository;" })
$ReverseSequences = @($Sequences | ForEach-Object { $_ -replace "air_repository_owner;","directus_repository;" })
$ReverseTables = @($Tables | ForEach-Object { $_ -replace "air_repository_owner;","directus_repository;" })
$ReverseSchemas = @($Schemas | ForEach-Object { $_ -replace "air_repository_owner;","directus_repository;" })
$ReverseStatements = @($ReverseFunctions) + @($ReverseSequences) + @($ReverseTables) + @($ReverseSchemas)
Assert-ExactCount "Reverse statements" 113 $ReverseStatements.Count
$InventorySql1 = "SELECT 'DATABASE||' || datname || '|' || pg_get_userbyid(datdba) FROM pg_database WHERE datname='directus_repository' AND pg_get_userbyid(datdba)='directus_repository';"
$InventorySql2 = "SELECT 'SCHEMA||' || nspname || '|' || pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname IN ('core','reporting','staging','phase2_staging') AND pg_get_userbyid(nspowner)='directus_repository' ORDER BY nspname;"
$InventorySql3 = "SELECT CASE WHEN c.relkind='S' THEN 'SEQUENCE' WHEN c.relkind='p' THEN 'PARTITIONED TABLE' ELSE 'TABLE' END || '|' || n.nspname || '|' || c.relname || '|' || pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p','S') AND pg_get_userbyid(c.relowner)='directus_repository' AND NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e') ORDER BY n.nspname,c.relname;"
$InventorySql4 = "SELECT 'FUNCTION|' || n.nspname || '|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || pg_get_userbyid(p.proowner) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.oid=to_regprocedure('staging.assert_row_count(regclass,bigint)') AND pg_get_userbyid(p.proowner)='directus_repository';"
$InventoryLines = @()
$InventoryLines += @(Invoke-RepositoryPsql $InventorySql1)
$InventoryLines += @(Invoke-RepositoryPsql $InventorySql2)
$InventoryLines += @(Invoke-RepositoryPsql $InventorySql3)
$InventoryLines += @(Invoke-RepositoryPsql $InventorySql4)
Assert-ExactCount "Inventory rows" 114 $InventoryLines.Count
$Inventory = @()
foreach ($Line in $InventoryLines) {
$Parts = @($Line -split "\|",4)
if ($Parts.Count -ne 4) { throw ("Invalid inventory row: " + $Line) }
$Inventory += [pscustomobject]@{ObjectType=$Parts[0];SchemaName=$Parts[1];ObjectName=$Parts[2];CurrentOwner=$Parts[3]}
}
$ForwardPath = Join-Path $BuildDir "gate5_0_targeted_ownership_forward.sql"
$RehearsalPath = Join-Path $BuildDir "gate5_0_targeted_ownership_rehearsal.sql"
$ReversePath = Join-Path $BuildDir "gate5_0_targeted_ownership_reverse.sql"
$DbForwardPath = Join-Path $BuildDir "gate5_0_database_owner_forward.sql"
$DbReversePath = Join-Path $BuildDir "gate5_0_database_owner_reverse.sql"
$InventoryPath = Join-Path $BuildDir "gate5_0_ownership_inventory_before.csv"
$ManifestPath = Join-Path $BuildDir "gate5_0_ownership_artifact_manifest.csv"
$Header = @("\set ON_ERROR_STOP on","BEGIN;","SET LOCAL lock_timeout = '5s';","SET LOCAL statement_timeout = '120s';")
Write-AsciiFile $ForwardPath (@($Header) + @($ForwardStatements) + @("COMMIT;"))
Write-AsciiFile $RehearsalPath (@($Header) + @($ForwardStatements) + @("ROLLBACK;"))
Write-AsciiFile $ReversePath (@($Header) + @($ReverseStatements) + @("COMMIT;"))
Write-AsciiFile $DbForwardPath @("\set ON_ERROR_STOP on","ALTER DATABASE directus_repository OWNER TO air_repository_owner;")
Write-AsciiFile $DbReversePath @("\set ON_ERROR_STOP on","ALTER DATABASE directus_repository OWNER TO directus_repository;")
$Inventory | Export-Csv -LiteralPath $InventoryPath -NoTypeInformation -Encoding ASCII
$SqlFiles = @($ForwardPath,$RehearsalPath,$ReversePath,$DbForwardPath,$DbReversePath)
$Forbidden = "(?i)(REASSIGN\s+OWNED|tiger|tiger_data|topology|spatial_ref_sys)"
foreach ($File in $SqlFiles) {
$Text = [System.IO.File]::ReadAllText($File)
if ([string]::IsNullOrWhiteSpace($Text)) { throw ("Empty artifact: " + $File) }
if ($Text -match $Forbidden) { throw ("Prohibited scope in: " + $File) }
}
if (-not ([System.IO.File]::ReadAllText($ForwardPath).TrimEnd().EndsWith("COMMIT;"))) { throw "Forward file ending invalid." }
if (-not ([System.IO.File]::ReadAllText($RehearsalPath).TrimEnd().EndsWith("ROLLBACK;"))) { throw "Rehearsal file ending invalid." }
if (-not ([System.IO.File]::ReadAllText($ReversePath).TrimEnd().EndsWith("COMMIT;"))) { throw "Reverse file ending invalid." }
$Artifacts = @($ForwardPath,$RehearsalPath,$ReversePath,$DbForwardPath,$DbReversePath,$InventoryPath)
foreach ($File in $Artifacts) {
$Bad = @([System.IO.File]::ReadAllBytes($File) | Where-Object { $_ -gt 127 })
if ($Bad.Count -ne 0) { throw ("Non-ASCII artifact: " + $File) }
}
$Manifest = @()
foreach ($File in $Artifacts) {
$Item = Get-Item -LiteralPath $File
$Manifest += [pscustomobject]@{File=$Item.Name;Bytes=$Item.Length;SHA256=(Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash}
}
Assert-ExactCount "Manifest entries" 6 $Manifest.Count
$Manifest | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding ASCII
Move-Item -LiteralPath $BuildDir -Destination $FinalDir
Write-Host "GATE 5.0 OWNERSHIP ARTIFACT GENERATION - PASS" -ForegroundColor Green
Write-Host ("ArtifactDirectory=" + $FinalDir)
foreach ($Count in $Counts) { Write-Host $Count }
Write-Host "TotalStatements=113"
Write-Host "InventoryRows=114"
Write-Host "ArtifactFingerprints:"
$Manifest | Format-Table File,Bytes,SHA256 -AutoSize
Write-Host "NO GENERATED SQL WAS EXECUTED." -ForegroundColor Green
Write-Host "STOP. DO NOT EXECUTE THE GENERATED SQL FILES." -ForegroundColor Yellow
}
catch {
if (Test-Path -LiteralPath $BuildDir) {
if (Test-Path -LiteralPath $FailedDir) { $FailedDir = $FailedDir + "_" + [guid]::NewGuid().ToString("N").Substring(0,8) }
Move-Item -LiteralPath $BuildDir -Destination $FailedDir
Write-Host ("FailedDirectory=" + $FailedDir) -ForegroundColor Yellow
}
Write-Host "GATE 5.0 OWNERSHIP ARTIFACT GENERATION - FAILED" -ForegroundColor Red
Write-Host ("Reason=" + $_.Exception.Message) -ForegroundColor Red
Write-Host "NO GENERATED SQL WAS EXECUTED." -ForegroundColor Yellow
exit 1
}