Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ArtifactDir = "C:\Directus\relational-repository\sql\gate5\ownership_20261002_071029"
$DatabaseContainer = "relational-repository-database-1"
$DirectusContainer = "relational-repository-directus-1"
$CacheContainer = "relational-repository-cache-1"
$DirectusStopped = $false
$ForwardAttempted = $false
function Fail {
    param([string]$Message)
    throw $Message
}
function Count-Pattern {
    param([string]$Text,[string]$Pattern)
    return [regex]::Matches($Text,$Pattern,[System.Text.RegularExpressions.RegexOptions]::Multiline).Count
}
function Invoke-Psql {
    param([string]$Sql)
    $OldPreference = $ErrorActionPreference
    $Raw = @()
    $Code = -1
    try {
        $ErrorActionPreference = "Continue"
        $Raw = @($Sql | & docker.exe exec -i $DatabaseContainer sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -q -t -A -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $OldPreference
    }
    $Lines = @()
    foreach ($Item in $Raw) {
        foreach ($Line in ([string]$Item -split "`r?`n")) {
            $Value = $Line.Trim()
            if ($Value.Length -gt 0) {
                $Lines += $Value
            }
        }
    }
    if ($Code -ne 0) {
        Fail ("psql failed with exit code " + $Code + ": " + ($Lines -join " | "))
    }
    return $Lines
}
function Get-ContainerHealth {
    param([string]$Container)
    $Value = @(& docker.exe inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" $Container 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Fail ("Cannot inspect container: " + $Container)
    }
    return ([string]$Value[0]).Trim()
}
function Start-DirectusAndWait {
    $null = & docker.exe start $DirectusContainer 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "Directus could not be started."
    }
    for ($Attempt = 1; $Attempt -le 60; $Attempt++) {
        $Health = Get-ContainerHealth $DirectusContainer
        if ($Health -eq "healthy") {
            return
        }
        Start-Sleep -Seconds 2
    }
    Fail ("Directus did not return healthy. Last status: " + $Health)
}
function Compare-State {
    param([string[]]$Expected,[string[]]$Actual,[string]$Label)
    $Difference = @(Compare-Object ($Expected | Sort-Object) ($Actual | Sort-Object))
    if ($Difference.Count -ne 0) {
        Fail ($Label + " failed. Observed: " + ($Actual -join ", "))
    }
}
function Invoke-ForwardFile {
    param([string]$Path)
    $SqlText = [System.IO.File]::ReadAllText($Path)
    $OldPreference = $ErrorActionPreference
    $Raw = @()
    $Code = -1
    try {
        $ErrorActionPreference = "Continue"
        $Raw = @($SqlText | & docker.exe exec -i $DatabaseContainer sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $OldPreference
    }
    $Text = ($Raw | ForEach-Object { [string]$_ }) -join "`r`n"
    if ($Code -ne 0) {
        Fail ("Forward ownership transaction failed with exit code " + $Code + ":`r`n" + $Text)
    }
    if ($Text -notmatch "(?m)^COMMIT\s*$") {
        Fail "Forward execution did not report a COMMIT command tag."
    }
    if ($Text -match "(?m)^ERROR:") {
        Fail "Forward output contains a PostgreSQL ERROR."
    }
    return $Text
}
$StateSql = @'
SELECT 'bootstrap_schemas=' || count(*) FROM pg_namespace WHERE nspname IN ('core','reporting','staging','phase2_staging') AND pg_get_userbyid(nspowner)='directus_repository';
SELECT 'owner_schemas=' || count(*) FROM pg_namespace WHERE nspname IN ('core','reporting','staging','phase2_staging') AND pg_get_userbyid(nspowner)='air_repository_owner';
SELECT 'bootstrap_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='directus_repository';
SELECT 'owner_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'bootstrap_sequences=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='S' AND pg_get_userbyid(c.relowner)='directus_repository';
SELECT 'owner_sequences=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='S' AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'bootstrap_functions=' || count(*) FROM pg_proc WHERE oid=to_regprocedure('staging.assert_row_count(regclass,bigint)') AND pg_get_userbyid(proowner)='directus_repository';
SELECT 'owner_functions=' || count(*) FROM pg_proc WHERE oid=to_regprocedure('staging.assert_row_count(regclass,bigint)') AND pg_get_userbyid(proowner)='air_repository_owner';
SELECT 'bootstrap_indexes=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='i' AND pg_get_userbyid(c.relowner)='directus_repository';
SELECT 'owner_indexes=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='i' AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'database_bootstrap_owner=' || count(*) FROM pg_database WHERE datname='directus_repository' AND pg_get_userbyid(datdba)='directus_repository';
SELECT 'database_air_owner=' || count(*) FROM pg_database WHERE datname='directus_repository' AND pg_get_userbyid(datdba)='air_repository_owner';
SELECT 'owner_role_valid=' || count(*) FROM pg_roles WHERE rolname='air_repository_owner' AND NOT rolsuper AND NOT rolcanlogin AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'runtime_role_valid=' || count(*) FROM pg_roles WHERE rolname='directus_runtime' AND NOT rolsuper AND rolcanlogin AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'runtime_owner_membership=' || count(*) FROM pg_auth_members m JOIN pg_roles mr ON mr.oid=m.member JOIN pg_roles gr ON gr.oid=m.roleid WHERE mr.rolname='directus_runtime' AND gr.rolname='air_repository_owner';
'@
$Gate4Sql = @'
SELECT 'report_rows=' || count(*) FROM reporting.course_current_catalog;
SELECT 'report_distinct_course_ids=' || count(DISTINCT course_id) FROM reporting.course_current_catalog;
SELECT 'core_course_rows=' || count(*) FROM core.course;
SELECT 'accepted_run=' || run_id::text || '|' || status || '|' || source_row_count::text || '|' || rows_inserted::text || '|' || rows_updated::text || '|' || rows_deleted::text || '|' || rows_unchanged::text || '|' || business_checksum FROM reporting.projection_refresh_run WHERE run_id='8eec3469-f834-4e90-b695-bb2384cc51e0'::uuid;
SELECT 'primary_keys=' || count(*) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('core','reporting') AND con.contype='p';
SELECT 'foreign_keys=' || count(*) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('core','reporting') AND con.contype='f';
SELECT 'directus_collections=' || count(*) FROM public.directus_collections;
SELECT 'directus_fields=' || count(*) FROM public.directus_fields;
SELECT 'directus_relations=' || count(*) FROM public.directus_relations;
SELECT 'directus_permissions=' || count(*) FROM public.directus_permissions;
'@
$ExcludedSql = @'
SELECT 'SCHEMA|' || nspname || '|' || pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname IN ('tiger','tiger_data','topology')
UNION ALL
SELECT 'RELATION|' || n.nspname || '|' || c.relkind::text || '|' || c.relname || '|' || pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('tiger','tiger_data','topology') OR (n.nspname='public' AND c.relname='spatial_ref_sys')
UNION ALL
SELECT 'EXTENSION|' || extname || '|' || pg_get_userbyid(extowner) FROM pg_extension
UNION ALL
SELECT 'EXTENSION_RELATION|' || n.nspname || '|' || c.relname || '|' || pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_depend d ON d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e' JOIN pg_extension e ON e.oid=d.refobjid
UNION ALL
SELECT 'EXTENSION_FUNCTION|' || n.nspname || '|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || pg_get_userbyid(p.proowner) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_depend d ON d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e' JOIN pg_extension e ON e.oid=d.refobjid
ORDER BY 1;
'@
try {
    $ExpectedFiles = @("gate5_0_database_owner_forward.sql","gate5_0_database_owner_reverse.sql","gate5_0_ownership_artifact_manifest.csv","gate5_0_ownership_inventory_before.csv","gate5_0_targeted_ownership_forward.sql","gate5_0_targeted_ownership_rehearsal.sql","gate5_0_targeted_ownership_reverse.sql") | Sort-Object
    $ActualFiles = @(Get-ChildItem -LiteralPath $ArtifactDir -File | Select-Object -ExpandProperty Name | Sort-Object)
    if (@(Compare-Object $ExpectedFiles $ActualFiles).Count -ne 0) { Fail "Authoritative artifact file set changed." }
    $ForwardPath = Join-Path $ArtifactDir "gate5_0_targeted_ownership_forward.sql"
    $ManifestPath = Join-Path $ArtifactDir "gate5_0_ownership_artifact_manifest.csv"
    $Manifest = @(Import-Csv -LiteralPath $ManifestPath)
    if ($Manifest.Count -ne 6) { Fail "Manifest does not contain six primary artifacts." }
    foreach ($Row in $Manifest) {
        $Path = Join-Path $ArtifactDir $Row.File
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail ("Missing artifact: " + $Row.File) }
        if ((Get-Item -LiteralPath $Path).Length -ne [int64]$Row.Bytes) { Fail ("Byte count changed: " + $Row.File) }
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Row.SHA256) { Fail ("SHA256 changed: " + $Row.File) }
    }
    $ForwardText = [System.IO.File]::ReadAllText($ForwardPath)
    if ((Count-Pattern $ForwardText "^ALTER TABLE ") -ne 96) { Fail "Forward table count is not 96." }
    if ((Count-Pattern $ForwardText "^ALTER SEQUENCE ") -ne 12) { Fail "Forward sequence count is not 12." }
    if ((Count-Pattern $ForwardText "^ALTER SCHEMA ") -ne 4) { Fail "Forward schema count is not 4." }
    if ((Count-Pattern $ForwardText "^ALTER FUNCTION ") -ne 1) { Fail "Forward function count is not 1." }
    if ((Count-Pattern $ForwardText "^COMMIT;\s*$") -ne 1) { Fail "Forward file must contain exactly one COMMIT." }
    if (-not $ForwardText.TrimEnd().EndsWith("COMMIT;")) { Fail "Forward file does not end in COMMIT." }
    if ($ForwardText -match "(?mi)^ALTER DATABASE ") { Fail "Forward file contains ALTER DATABASE." }
    if ($ForwardText -match "(?mi)^ROLLBACK;") { Fail "Forward file contains ROLLBACK." }
    if ($ForwardText -match "(?i)\b(REASSIGN\s+OWNED|tiger|tiger_data|topology|spatial_ref_sys)\b") { Fail "Forward file contains prohibited scope." }
    $ExpectedBefore = @("bootstrap_schemas=4","owner_schemas=0","bootstrap_tables=96","owner_tables=0","bootstrap_sequences=12","owner_sequences=0","bootstrap_functions=1","owner_functions=0","bootstrap_indexes=113","owner_indexes=0","database_bootstrap_owner=1","database_air_owner=0","owner_role_valid=1","runtime_role_valid=1","runtime_owner_membership=0")
    $ExpectedAfter = @("bootstrap_schemas=0","owner_schemas=4","bootstrap_tables=0","owner_tables=96","bootstrap_sequences=0","owner_sequences=12","bootstrap_functions=0","owner_functions=1","bootstrap_indexes=0","owner_indexes=113","database_bootstrap_owner=1","database_air_owner=0","owner_role_valid=1","runtime_role_valid=1","runtime_owner_membership=0")
    $BeforeState = @(Invoke-Psql $StateSql)
    Compare-State $ExpectedBefore $BeforeState "Pre-transfer ownership state"
    $ExpectedGate4 = @("report_rows=966","report_distinct_course_ids=966","core_course_rows=966","accepted_run=8eec3469-f834-4e90-b695-bb2384cc51e0|COMPLETED|966|0|0|0|966|666d67d56d4c492ea0cdd7a63a7f85fd","primary_keys=17","foreign_keys=56","directus_collections=0","directus_fields=0","directus_relations=0","directus_permissions=0")
    $BeforeGate4 = @(Invoke-Psql $Gate4Sql)
    Compare-State $ExpectedGate4 $BeforeGate4 "Pre-transfer Gate 4 baseline"
    $ExcludedBefore = @(Invoke-Psql $ExcludedSql)
    if ($ExcludedBefore.Count -eq 0) { Fail "Excluded-object baseline is empty." }
    if ((Get-ContainerHealth $DatabaseContainer) -ne "healthy") { Fail "PostgreSQL is not healthy." }
    if ((Get-ContainerHealth $CacheContainer) -ne "healthy") { Fail "Redis is not healthy." }
    if ((Get-ContainerHealth $DirectusContainer) -ne "healthy") { Fail "Directus is not healthy before transfer." }
    $null = & docker.exe stop $DirectusContainer 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "Directus could not be stopped." }
    $DirectusStopped = $true
    $Sessions = @(Invoke-Psql "SELECT count(*) FROM pg_stat_activity WHERE usename='directus_repository' AND backend_type='client backend' AND pid<>pg_backend_pid();")
    if ($Sessions.Count -ne 1 -or $Sessions[0] -ne "0") { Fail ("Unexpected directus_repository sessions remain: " + ($Sessions -join ",")) }
    $ForwardAttempted = $true
    $null = Invoke-ForwardFile $ForwardPath
    $AfterState = @(Invoke-Psql $StateSql)
    Compare-State $ExpectedAfter $AfterState "Post-transfer ownership state"
    $AfterGate4 = @(Invoke-Psql $Gate4Sql)
    Compare-State $ExpectedGate4 $AfterGate4 "Post-transfer Gate 4 baseline"
    Compare-State $BeforeGate4 $AfterGate4 "Pre/post Gate 4 comparison"
    $ExcludedAfter = @(Invoke-Psql $ExcludedSql)
    Compare-State $ExcludedBefore $ExcludedAfter "Excluded object ownership comparison"
    Start-DirectusAndWait
    $DirectusStopped = $false
    Write-Host "GATE 5.0 TARGETED OWNERSHIP TRANSFER - PASS" -ForegroundColor Green
    Write-Host ("ArtifactDirectory=" + $ArtifactDir)
    Write-Host "ManifestVerification=PASS"
    Write-Host "ForwardPsqlExitCode=0"
    Write-Host "ForwardReachedCommit=YES"
    Write-Host "TransferredSchemas=4"
    Write-Host "TransferredTables=96"
    Write-Host "TransferredSequences=12"
    Write-Host "TransferredFunctions=1"
    Write-Host "TransferredIndexesByTableOwnership=113"
    Write-Host "BootstrapTargetOwnershipRemaining=0"
    Write-Host "DatabaseOwner=directus_repository"
    Write-Host "DatabaseOwnerArtifactExecuted=NO"
    Write-Host "ExcludedOwnershipChanges=0"
    Write-Host "Gate4Baseline=PASS"
    Write-Host "DirectusHealth=healthy"
    Write-Host "STOP. DO NOT EXECUTE DATABASE OWNER OR PRIVILEGE FILES." -ForegroundColor Yellow
}
catch {
    $OriginalError = $_.Exception.Message
    if ($DirectusStopped) {
        try {
            Start-DirectusAndWait
            Write-Host "DirectusRecovery=healthy" -ForegroundColor Yellow
        }
        catch {
            Write-Host ("DirectusRecovery=FAILED: " + $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Host "GATE 5.0 TARGETED OWNERSHIP TRANSFER - FAILED" -ForegroundColor Red
    Write-Host ("ForwardAttempted=" + $ForwardAttempted)
    Write-Host ("Reason=" + $OriginalError) -ForegroundColor Red
    try {
        $FailureState = @(Invoke-Psql $StateSql)
        foreach ($Line in $FailureState) { Write-Host $Line }
    }
    catch {
        Write-Host ("FailureStateQuery=FAILED: " + $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host "DATABASE OWNER FILE WAS NOT EXECUTED." -ForegroundColor Yellow
    Write-Host "REVERSE SQL WAS NOT AUTOMATICALLY EXECUTED." -ForegroundColor Yellow
    exit 1
}