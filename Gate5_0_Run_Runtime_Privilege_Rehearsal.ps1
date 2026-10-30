Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ArtifactDir = "C:\Directus\relational-repository\sql\gate5\runtime_privileges_20261002_074331"
$DatabaseContainer = "relational-repository-database-1"
$DirectusContainer = "relational-repository-directus-1"
$CacheContainer = "relational-repository-cache-1"
$DirectusStopped = $false
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
    $Old = $ErrorActionPreference
    $Raw = @()
    $Code = -1
    try {
        $ErrorActionPreference = "Continue"
        $Raw = @($Sql | & docker.exe exec -i $DatabaseContainer sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -q -t -A -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Old
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
function Compare-State {
    param([string[]]$Before,[string[]]$After,[string]$Label)
    $Difference = @(Compare-Object ($Before | Sort-Object) ($After | Sort-Object))
    if ($Difference.Count -ne 0) {
        Fail ($Label + " differs:`r`n" + (($Difference | Format-Table -AutoSize | Out-String).Trim()))
    }
}
function Assert-State {
    param([string[]]$Expected,[string[]]$Actual,[string]$Label)
    $Difference = @(Compare-Object ($Expected | Sort-Object) ($Actual | Sort-Object))
    if ($Difference.Count -ne 0) {
        Fail ($Label + " failed. Observed: " + ($Actual -join ", "))
    }
}
function Get-Health {
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
        $Health = Get-Health $DirectusContainer
        if ($Health -eq "healthy") {
            return
        }
        Start-Sleep -Seconds 2
    }
    Fail ("Directus did not return healthy. Last status: " + $Health)
}
function Invoke-Rehearsal {
    param([string]$Path)
    $SqlText = [System.IO.File]::ReadAllText($Path)
    $Old = $ErrorActionPreference
    $Raw = @()
    $Code = -1
    try {
        $ErrorActionPreference = "Continue"
        $Raw = @($SqlText | & docker.exe exec -i $DatabaseContainer sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Old
    }
    $Text = ($Raw | ForEach-Object { [string]$_ }) -join "`r`n"
    if ($Code -ne 0) {
        Fail ("Rehearsal failed with exit code " + $Code + ":`r`n" + $Text)
    }
    if ($Text -match "(?m)^ERROR:") {
        Fail "Rehearsal output contains a PostgreSQL ERROR."
    }
    if ($Text -notmatch "(?m)^ROLLBACK\s*$") {
        Fail "Rehearsal output does not contain the successful ROLLBACK command tag."
    }
    $CommandTags = [regex]::Matches($Text,"(?m)^(GRANT|REVOKE)\s*$").Count
    if ($CommandTags -ne 91) {
        Fail ("Expected 91 GRANT/REVOKE command tags but observed " + $CommandTags + ".")
    }
    return $Text
}
$ControlSql = @'
SELECT 'runtime_role_valid=' || count(*) FROM pg_roles WHERE rolname='directus_runtime' AND rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'runtime_owner_membership=' || count(*) FROM pg_auth_members m JOIN pg_roles mr ON mr.oid=m.member JOIN pg_roles gr ON gr.oid=m.roleid WHERE mr.rolname='directus_runtime' AND gr.rolname='air_repository_owner';
SELECT 'runtime_owned_objects=' || count(*) FROM pg_class WHERE pg_get_userbyid(relowner)='directus_runtime';
SELECT 'owner_schemas=' || count(*) FROM pg_namespace WHERE nspname IN ('core','reporting','staging','phase2_staging') AND pg_get_userbyid(nspowner)='air_repository_owner';
SELECT 'owner_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'owner_sequences=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='S' AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'owner_functions=' || count(*) FROM pg_proc WHERE oid=to_regprocedure('staging.assert_row_count(regclass,bigint)') AND pg_get_userbyid(proowner)='air_repository_owner';
SELECT 'database_bootstrap_owner=' || count(*) FROM pg_database WHERE datname='directus_repository' AND pg_get_userbyid(datdba)='directus_repository';
SELECT 'owner_default_acl_entries=' || count(*) FROM pg_default_acl d JOIN pg_roles r ON r.oid=d.defaclrole WHERE r.rolname='air_repository_owner';
SELECT 'staging_usage=' || CASE WHEN has_schema_privilege('directus_runtime','staging','USAGE') THEN 1 ELSE 0 END;
SELECT 'phase2_usage=' || CASE WHEN has_schema_privilege('directus_runtime','phase2_staging','USAGE') THEN 1 ELSE 0 END;
SELECT 'staging_table_access=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='staging' AND c.relkind IN ('r','p') AND (has_table_privilege('directus_runtime',c.oid,'SELECT') OR has_table_privilege('directus_runtime',c.oid,'INSERT') OR has_table_privilege('directus_runtime',c.oid,'UPDATE') OR has_table_privilege('directus_runtime',c.oid,'DELETE'));
SELECT 'phase2_table_access=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='phase2_staging' AND c.relkind IN ('r','p') AND (has_table_privilege('directus_runtime',c.oid,'SELECT') OR has_table_privilege('directus_runtime',c.oid,'INSERT') OR has_table_privilege('directus_runtime',c.oid,'UPDATE') OR has_table_privilege('directus_runtime',c.oid,'DELETE'));
SELECT 'public_function_execute=' || CASE WHEN has_function_privilege('public','staging.assert_row_count(regclass,bigint)','EXECUTE') THEN 1 ELSE 0 END;
SELECT 'runtime_function_execute=' || CASE WHEN has_function_privilege('directus_runtime','staging.assert_row_count(regclass,bigint)','EXECUTE') THEN 1 ELSE 0 END;
'@
$SnapshotSql = @'
SELECT 'DATABASE|' || datname || '|' || pg_get_userbyid(datdba) || '|' || coalesce(datacl::text,'NULL') FROM pg_database WHERE datname='directus_repository';
SELECT 'SCHEMA|' || nspname || '|' || pg_get_userbyid(nspowner) || '|' || coalesce(nspacl::text,'NULL') FROM pg_namespace WHERE nspname IN ('public','core','reporting','staging','phase2_staging') ORDER BY nspname;
SELECT 'RELATION|' || n.nspname || '|' || c.relname || '|' || c.relkind::text || '|' || pg_get_userbyid(c.relowner) || '|' || coalesce(c.relacl::text,'NULL') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p','S') ORDER BY n.nspname,c.relkind,c.relname;
SELECT 'COLUMN|' || n.nspname || '|' || c.relname || '|' || a.attnum::text || '|' || a.attname || '|' || a.attacl::text FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p') AND a.attacl IS NOT NULL ORDER BY n.nspname,c.relname,a.attnum;
SELECT 'FUNCTION|staging|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || pg_get_userbyid(p.proowner) || '|' || coalesce(p.proacl::text,'NULL') || '|security_definer=' || p.prosecdef::text FROM pg_proc p WHERE p.oid=to_regprocedure('staging.assert_row_count(regclass,bigint)');
SELECT 'DEFAULTACL|' || r.rolname || '|' || coalesce(n.nspname,'ALL') || '|' || d.defaclobjtype::text || '|' || d.defaclacl::text FROM pg_default_acl d JOIN pg_roles r ON r.oid=d.defaclrole LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace WHERE r.rolname IN ('air_repository_owner','directus_runtime') ORDER BY r.rolname,n.nspname,d.defaclobjtype;
SELECT 'ROLE|directus_runtime|' || rolsuper::text || '|' || rolcreaterole::text || '|' || rolcreatedb::text || '|' || rolcanlogin::text || '|' || rolreplication::text || '|' || rolbypassrls::text FROM pg_roles WHERE rolname='directus_runtime';
SELECT 'MEMBERSHIP|' || mr.rolname || '|' || gr.rolname FROM pg_auth_members m JOIN pg_roles mr ON mr.oid=m.member JOIN pg_roles gr ON gr.oid=m.roleid WHERE mr.rolname='directus_runtime' ORDER BY gr.rolname;
'@
$Gate4Sql = @'
SELECT 'report_rows=' || count(*) FROM reporting.course_current_catalog;
SELECT 'report_distinct_course_ids=' || count(DISTINCT course_id) FROM reporting.course_current_catalog;
SELECT 'projection_runs=' || count(DISTINCT report_refresh_run_id) FROM reporting.course_current_catalog;
SELECT 'report_as_of_values=' || count(DISTINCT report_as_of_utc) FROM reporting.course_current_catalog;
SELECT 'core_current_rows=' || count(*) FROM core.course WHERE is_current IS TRUE;
SELECT 'core_distinct_course_ids=' || count(DISTINCT course_id) FROM core.course WHERE is_current IS TRUE;
SELECT 'required_failures=' || count(*) FILTER (WHERE course_id IS NULL OR source_identifier IS NULL OR btrim(source_identifier)='' OR course_code IS NULL OR btrim(course_code)='' OR course_title IS NULL OR btrim(course_title)='' OR import_batch_id IS NULL) FROM core.course WHERE is_current IS TRUE;
SELECT 'duplicate_source_groups=' || count(*) FROM (SELECT source_identifier FROM core.course WHERE is_current IS TRUE GROUP BY source_identifier HAVING count(*)>1) d;
SELECT 'second_batch=' || count(*) FROM core.course WHERE is_current IS TRUE AND import_batch_id='53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid;
SELECT 'prior_batch=' || count(*) FROM core.course WHERE is_current IS TRUE AND import_batch_id='06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid;
SELECT 'other_batches=' || count(*) FROM core.course WHERE is_current IS TRUE AND import_batch_id NOT IN ('53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,'06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid);
SELECT 'accepted_run=' || run_id::text || '|' || status || '|' || source_row_count::text || '|' || rows_inserted::text || '|' || rows_updated::text || '|' || rows_deleted::text || '|' || rows_unchanged::text || '|' || business_checksum FROM reporting.projection_refresh_run WHERE run_id='8eec3469-f834-4e90-b695-bb2384cc51e0'::uuid;
SELECT 'primary_keys=' || count(*) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('core','reporting') AND con.contype='p';
SELECT 'foreign_keys=' || count(*) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('core','reporting') AND con.contype='f';
SELECT 'directus_collections=' || count(*) FROM public.directus_collections;
SELECT 'directus_fields=' || count(*) FROM public.directus_fields;
SELECT 'directus_relations=' || count(*) FROM public.directus_relations;
SELECT 'directus_permissions=' || count(*) FROM public.directus_permissions;
'@
try {
    $ExpectedFiles = @(
        "gate5_0_runtime_privileges_before.csv",
        "gate5_0_runtime_privileges_forward.sql",
        "gate5_0_runtime_privileges_manifest.csv",
        "gate5_0_runtime_privileges_rehearsal.sql",
        "gate5_0_runtime_privileges_reverse.sql"
    ) | Sort-Object
    $ActualFiles = @(Get-ChildItem -LiteralPath $ArtifactDir -File | Select-Object -ExpandProperty Name | Sort-Object)
    if (@(Compare-Object $ExpectedFiles $ActualFiles).Count -ne 0) {
        Fail "Authoritative privilege artifact file set changed."
    }
    $ForwardPath = Join-Path $ArtifactDir "gate5_0_runtime_privileges_forward.sql"
    $RehearsalPath = Join-Path $ArtifactDir "gate5_0_runtime_privileges_rehearsal.sql"
    $ReversePath = Join-Path $ArtifactDir "gate5_0_runtime_privileges_reverse.sql"
    $InventoryPath = Join-Path $ArtifactDir "gate5_0_runtime_privileges_before.csv"
    $ManifestPath = Join-Path $ArtifactDir "gate5_0_runtime_privileges_manifest.csv"
    $Manifest = @(Import-Csv -LiteralPath $ManifestPath)
    if ($Manifest.Count -ne 4) {
        Fail ("Manifest expected 4 rows but contains " + $Manifest.Count + ".")
    }
    $ExpectedManifestFiles = @(
        "gate5_0_runtime_privileges_before.csv",
        "gate5_0_runtime_privileges_forward.sql",
        "gate5_0_runtime_privileges_rehearsal.sql",
        "gate5_0_runtime_privileges_reverse.sql"
    ) | Sort-Object
    $ActualManifestFiles = @($Manifest | Select-Object -ExpandProperty File | Sort-Object)
    if (@(Compare-Object $ExpectedManifestFiles $ActualManifestFiles).Count -ne 0) {
        Fail "Manifest filenames do not match the required four primary artifacts."
    }
    foreach ($Row in $Manifest) {
        $Path = Join-Path $ArtifactDir $Row.File
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Fail ("Manifest file missing: " + $Row.File)
        }
        if ((Get-Item -LiteralPath $Path).Length -ne [int64]$Row.Bytes) {
            Fail ("Manifest byte count mismatch: " + $Row.File)
        }
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Row.SHA256) {
            Fail ("Manifest hash mismatch: " + $Row.File)
        }
    }
    $ForwardText = [System.IO.File]::ReadAllText($ForwardPath)
    $RehearsalText = [System.IO.File]::ReadAllText($RehearsalPath)
    $ReverseText = [System.IO.File]::ReadAllText($ReversePath)
    $Forbidden = "(?im)^(ALTER|CREATE|DROP|INSERT|UPDATE|DELETE|TRUNCATE|COPY|PASSWORD|REASSIGN)\b|REASSIGN\s+OWNED|ALTER\s+DEFAULT\s+PRIVILEGES|tiger_data|tiger|topology|spatial_ref_sys"
    foreach ($Text in @($ForwardText,$RehearsalText,$ReverseText)) {
        if ($Text -match $Forbidden) {
            Fail "A privilege artifact contains prohibited SQL or prohibited scope."
        }
    }
    if ((Count-Pattern $ForwardText "^(GRANT|REVOKE) ") -ne 91) {
        Fail "Forward artifact does not contain exactly 91 GRANT/REVOKE statements."
    }
    if ((Count-Pattern $RehearsalText "^(GRANT|REVOKE) ") -ne 91) {
        Fail "Rehearsal artifact does not contain exactly 91 GRANT/REVOKE statements."
    }
    if (-not $ForwardText.TrimEnd().EndsWith("COMMIT;")) {
        Fail "Forward artifact does not end with COMMIT."
    }
    if (-not $RehearsalText.TrimEnd().EndsWith("ROLLBACK;")) {
        Fail "Rehearsal artifact does not end with ROLLBACK."
    }
    if ($RehearsalText -match "(?mi)^COMMIT;\s*$") {
        Fail "Rehearsal artifact contains COMMIT."
    }
    if ((Count-Pattern $RehearsalText "^ROLLBACK;\s*$") -ne 1) {
        Fail "Rehearsal artifact must contain exactly one ROLLBACK."
    }
    $ForwardNormalized = [regex]::Replace($ForwardText.TrimEnd(),"(?m)^COMMIT;\s*$","END;")
    $RehearsalNormalized = [regex]::Replace($RehearsalText.TrimEnd(),"(?m)^ROLLBACK;\s*$","END;")
    if ($ForwardNormalized -cne $RehearsalNormalized) {
        Fail "Forward and rehearsal differ beyond COMMIT versus ROLLBACK."
    }
    $ExpectedControls = @(
        "runtime_role_valid=1",
        "runtime_owner_membership=0",
        "runtime_owned_objects=0",
        "owner_schemas=4",
        "owner_tables=96",
        "owner_sequences=12",
        "owner_functions=1",
        "database_bootstrap_owner=1",
        "owner_default_acl_entries=0",
        "staging_usage=0",
        "phase2_usage=0",
        "staging_table_access=0",
        "phase2_table_access=0",
        "public_function_execute=1",
        "runtime_function_execute=1"
    )
    $BeforeControls = @(Invoke-Psql $ControlSql)
    Assert-State $ExpectedControls $BeforeControls "Pre-rehearsal controls"
    $ExpectedGate4 = @(
        "report_rows=966",
        "report_distinct_course_ids=966",
        "projection_runs=1",
        "report_as_of_values=1",
        "core_current_rows=966",
        "core_distinct_course_ids=966",
        "required_failures=0",
        "duplicate_source_groups=0",
        "second_batch=5",
        "prior_batch=961",
        "other_batches=0",
        "accepted_run=8eec3469-f834-4e90-b695-bb2384cc51e0|COMPLETED|966|0|0|0|966|666d67d56d4c492ea0cdd7a63a7f85fd",
        "primary_keys=17",
        "foreign_keys=56",
        "directus_collections=0",
        "directus_fields=0",
        "directus_relations=0",
        "directus_permissions=0"
    )
    $BeforeGate4 = @(Invoke-Psql $Gate4Sql)
    Assert-State $ExpectedGate4 $BeforeGate4 "Pre-rehearsal Gate 4 baseline"
    $BeforeSnapshot = @(Invoke-Psql $SnapshotSql)
    if ($BeforeSnapshot.Count -eq 0) {
        Fail "Pre-rehearsal ACL snapshot is empty."
    }
    if ((Get-Health $DatabaseContainer) -ne "healthy") {
        Fail "PostgreSQL is not healthy."
    }
    if ((Get-Health $CacheContainer) -ne "healthy") {
        Fail "Redis is not healthy."
    }
    if ((Get-Health $DirectusContainer) -ne "healthy") {
        Fail "Directus is not healthy before rehearsal."
    }
    $null = & docker.exe stop $DirectusContainer 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "Directus could not be stopped."
    }
    $DirectusStopped = $true
    $SessionCount = @(Invoke-Psql "SELECT count(*) FROM pg_stat_activity WHERE usename='directus_repository' AND backend_type='client backend' AND pid<>pg_backend_pid();")
    if ($SessionCount.Count -ne 1 -or $SessionCount[0] -ne "0") {
        Fail ("Unexpected directus_repository client sessions remain: " + ($SessionCount -join ","))
    }
    $null = Invoke-Rehearsal $RehearsalPath
    $AfterSnapshot = @(Invoke-Psql $SnapshotSql)
    Compare-State $BeforeSnapshot $AfterSnapshot "ACL catalog snapshot"
    $AfterControls = @(Invoke-Psql $ControlSql)
    Assert-State $ExpectedControls $AfterControls "Post-rehearsal controls"
    Compare-State $BeforeControls $AfterControls "Pre/post control comparison"
    $AfterGate4 = @(Invoke-Psql $Gate4Sql)
    Assert-State $ExpectedGate4 $AfterGate4 "Post-rehearsal Gate 4 baseline"
    Compare-State $BeforeGate4 $AfterGate4 "Pre/post Gate 4 comparison"
    Start-DirectusAndWait
    $DirectusStopped = $false
    Write-Host "GATE 5.0 RUNTIME PRIVILEGE REHEARSAL - PASS" -ForegroundColor Green
    Write-Host ("ArtifactDirectory=" + $ArtifactDir)
    Write-Host "ArtifactReview=PASS"
    Write-Host "ManifestVerification=PASS"
    Write-Host "PrivilegeStatementsExecuted=91"
    Write-Host "RehearsalPsqlExitCode=0"
    Write-Host "RehearsalReachedRollback=YES"
    Write-Host "PersistentPrivilegeChanges=0"
    Write-Host "AclSnapshotMatch=PASS"
    foreach ($Line in $AfterControls) {
        Write-Host $Line
    }
    Write-Host "Gate4Baseline=PASS"
    Write-Host "DirectusHealth=healthy"
    Write-Host "ForwardPrivilegeArtifactExecuted=NO"
    Write-Host "ReversePrivilegeArtifactExecuted=NO"
    Write-Host "STOP. DO NOT EXECUTE THE FORWARD PRIVILEGE SQL." -ForegroundColor Yellow
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
    Write-Host "GATE 5.0 RUNTIME PRIVILEGE REHEARSAL - FAILED" -ForegroundColor Red
    Write-Host ("Reason=" + $OriginalError) -ForegroundColor Red
    Write-Host "FORWARD PRIVILEGE SQL WAS NOT EXECUTED." -ForegroundColor Yellow
    Write-Host "REVERSE PRIVILEGE SQL WAS NOT EXECUTED." -ForegroundColor Yellow
    exit 1
}