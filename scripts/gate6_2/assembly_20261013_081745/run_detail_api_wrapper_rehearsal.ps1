[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = "C:\Directus\relational-repository"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$evidenceDir = Join-Path $root ("evidence\gate6\gate6_2\detail_api_wrapper_rehearsal_" + $stamp)
$sqlPath = Join-Path $evidenceDir "course_catalog_detail_api_wrapper_rehearsal.sql"
$mainPath = Join-Path $evidenceDir "rehearsal-output.txt"
$postPath = Join-Path $evidenceDir "post-rollback-output.txt"
$recordPath = Join-Path $evidenceDir "rehearsal-record.json"
$sourceArtifact = Join-Path $root "sql\gate6_2\directus_course_catalog_detail_metadata_permission_commit.sql"
$expectedSourceHash = "F07D5FA34FE16C4466E25A1CF2554179C261E56B9D2D18ED353E2933429E9511"
$tokenPath = Join-Path $root ".secrets\wwairml_directus_static_token.txt"
$baseUrl = "http://127.0.0.1:8066"

New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null

if (-not (Test-Path -LiteralPath $sourceArtifact -PathType Leaf)) {
    throw "STOP - frozen Gate 6.2 COMMIT artifact not found."
}

$sourceHash = (Get-FileHash -LiteralPath $sourceArtifact -Algorithm SHA256).Hash.ToUpperInvariant()

if ($sourceHash -ne $expectedSourceHash) {
    throw "STOP - source fingerprint mismatch. Expected=$expectedSourceHash Actual=$sourceHash"
}

Write-Output ("PASS|RUNNER_SOURCE_ARTIFACT_FINGERPRINT|" + $sourceHash)

function Invoke-Psql {
    param([Parameter(Mandatory=$true)][string]$SqlText)

    $arguments = @(
        "compose","exec","-T","database",
        "psql","-X",
        "-U","directus_repository",
        "-d","directus_repository",
        "-v","ON_ERROR_STOP=1",
        "-P","pager=off",
        "-A","-t","-f","-"
    )

    $output = @($SqlText | & docker @arguments 2>&1)
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
        Text = ($output -join "`n")
    }
}

if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
    throw "STOP - service-token file not found."
}

$token = [System.IO.File]::ReadAllText($tokenPath).Trim()

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "STOP - service-token file is empty."
}

$apiHeaders = @{
    Authorization = "Bearer " + $token
    Accept = "application/json"
    "Cache-Control" = "no-store"
}

function Invoke-DirectusProbe {
    param(
        [Parameter(Mandatory=$true)][string]$Uri
    )

    try {
        $body = Invoke-RestMethod -Method Get -Uri $Uri -Headers $apiHeaders -ErrorAction Stop

        return [pscustomobject]@{
            Status = 200
            Body = $body
        }
    }
    catch {
        $status = -1

        if ($null -ne $_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode }
            catch {}
        }

        return [pscustomobject]@{
            Status = $status
            Body = $null
        }
    }
}

function Get-AggregateCount {
    param([Parameter(Mandatory=$true)][object]$Probe)

    if (
        $Probe.Status -eq 200 -and
        $null -ne $Probe.Body -and
        $null -ne $Probe.Body.data -and
        @($Probe.Body.data).Count -gt 0 -and
        $null -ne @($Probe.Body.data)[0].count
    ) {
        return [string]@($Probe.Body.data)[0].count.course_id
    }

    return "<NOT_RETURNED>"
}

$stateSqlLines = [string[]]@(
    "BEGIN TRANSACTION READ ONLY;",
    "SELECT 'STATE_WRAPPER_RELATION|' || (to_regclass('reporting.course_catalog_detail_api') IS NOT NULL)::text;",
    "SELECT 'STATE_WRAPPER_COLLECTION|' || count(*) FROM directus_collections WHERE collection='course_catalog_detail_api';",
    "SELECT 'STATE_WRAPPER_PERMISSIONS|' || count(*) FROM directus_permissions WHERE collection='course_catalog_detail_api';",
    "SELECT 'STATE_WRAPPER_FIELDS|' || count(*) FROM directus_fields WHERE collection='course_catalog_detail_api';",
    "SELECT 'STATE_INTERNAL_COLLECTION|' || count(*) FROM directus_collections WHERE collection='course_catalog_detail';",
    "SELECT 'STATE_INTERNAL_PERMISSION|' || count(*) FROM directus_permissions WHERE collection='course_catalog_detail';",
    "SELECT 'STATE_INTERNAL_ROWS|' || count(*) FROM reporting.course_catalog_detail;",
    "SELECT 'STATE_FROZEN_ROWS|' || count(*) FROM reporting.course_current_catalog_api;",
    "SELECT 'STATE_FROZEN_PERMISSION|' || count(*) FROM directus_permissions WHERE collection='course_current_catalog_api';",
    "ROLLBACK;"
)

$stateSql = $stateSqlLines -join "`n"

$expectedState = @(
    "STATE_WRAPPER_RELATION|false",
    "STATE_WRAPPER_COLLECTION|0",
    "STATE_WRAPPER_PERMISSIONS|0",
    "STATE_WRAPPER_FIELDS|0",
    "STATE_INTERNAL_COLLECTION|1",
    "STATE_INTERNAL_PERMISSION|1",
    "STATE_INTERNAL_ROWS|964",
    "STATE_FROZEN_ROWS|966",
    "STATE_FROZEN_PERMISSION|1"
)

$preflight = Invoke-Psql -SqlText $stateSql
$preflight.Output | ForEach-Object { Write-Output $_ }

if ($preflight.ExitCode -ne 0) {
    throw "STOP - read-only database preflight failed with exit code $($preflight.ExitCode)."
}

foreach ($marker in $expectedState) {
    if ($preflight.Text -notmatch [regex]::Escape($marker)) {
        throw "STOP - clean-state preflight assertion failed: $marker"
    }
}

Write-Output "PASS|DATABASE_CLEAN_STATE_PREFLIGHT"

$frozenUri = $baseUrl + "/items/course_current_catalog_api?aggregate%5Bcount%5D=course_id"
$detailUri = $baseUrl + "/items/course_catalog_detail?aggregate%5Bcount%5D=course_id"
$wrapperUri = $baseUrl + "/items/course_catalog_detail_api?aggregate%5Bcount%5D=course_id"

$preFrozen = Invoke-DirectusProbe -Uri $frozenUri
$preDetail = Invoke-DirectusProbe -Uri $detailUri
$preFrozenCount = Get-AggregateCount -Probe $preFrozen

Write-Output ("PRE_API|frozen_http={0}|frozen_count={1}|detail_http={2}" -f $preFrozen.Status,$preFrozenCount,$preDetail.Status)

if ($preFrozen.Status -ne 200 -or $preFrozenCount -ne "966" -or $preDetail.Status -ne 403) {
    throw "STOP - API preflight boundary differs from the validated Gate 6.2 checkpoint."
}

Write-Output "PASS|API_BOUNDARY_PREFLIGHT"

$rehearsalSqlLines = [string[]]@(
    "BEGIN;",
    "SET LOCAL lock_timeout = '5s';",
    "SET LOCAL statement_timeout = '30s';",
    "";
    "DO `$gate`$";
    "DECLARE v bigint;";
    "BEGIN";
    "    IF to_regclass('reporting.course_catalog_detail_api') IS NOT NULL THEN";
    "        RAISE EXCEPTION 'Wrapper relation already exists';";
    "    END IF;";
    "";
    "    SELECT count(*) INTO v FROM reporting.course_catalog_detail;";
    "    IF v <> 964 THEN RAISE EXCEPTION 'Internal detail row count changed'; END IF;";
    "";
    "    SELECT count(*) INTO v FROM reporting.course_current_catalog_api;";
    "    IF v <> 966 THEN RAISE EXCEPTION 'Frozen API row count changed'; END IF;";
    "";
    "    SELECT count(*) INTO v FROM directus_collections WHERE collection='course_catalog_detail';";
    "    IF v <> 1 THEN RAISE EXCEPTION 'Internal detail collection baseline changed'; END IF;";
    "";
    "    SELECT count(*) INTO v FROM directus_permissions WHERE collection='course_catalog_detail';";
    "    IF v <> 1 THEN RAISE EXCEPTION 'Internal detail permission baseline changed'; END IF;";
    "";
    "    SELECT count(*) INTO v FROM directus_permissions WHERE collection='course_current_catalog_api';";
    "    IF v <> 1 THEN RAISE EXCEPTION 'Frozen permission baseline changed'; END IF;";
    "END";
    "`$gate`$;";
    "";
    "CREATE TABLE reporting.course_catalog_detail_api (";
    "    course_id uuid NOT NULL,";
    "    university_course_id text,";
    "    course_code text,";
    "    course_title text,";
    "    college_name text,";
    "    course_description text,";
    "    course_goals text,";
    "    course_learning_outcomes text,";
    "    CONSTRAINT course_catalog_detail_api_pkey PRIMARY KEY (course_id)";
    ");"
)

$rehearsalSqlLines += [string[]]@(
    "";
    "INSERT INTO reporting.course_catalog_detail_api (";
    "    course_id,";
    "    university_course_id,";
    "    course_code,";
    "    course_title,";
    "    college_name,";
    "    course_description,";
    "    course_goals,";
    "    course_learning_outcomes";
    ")";
    "SELECT";
    "    course_id,";
    "    university_course_id,";
    "    course_code,";
    "    course_title,";
    "    college_name,";
    "    course_description,";
    "    course_goals,";
    "    course_learning_outcomes";
    "FROM reporting.course_catalog_detail;";
    "";
    "ALTER TABLE reporting.course_catalog_detail_api OWNER TO air_repository_owner;";
    "REVOKE ALL ON TABLE reporting.course_catalog_detail_api FROM PUBLIC;";
    "GRANT SELECT ON TABLE reporting.course_catalog_detail_api TO directus_runtime;"
)

$rehearsalSqlLines += [string[]]@(
    "";
    "DELETE FROM directus_permissions WHERE collection='course_catalog_detail';";
    "DELETE FROM directus_collections WHERE collection='course_catalog_detail';";
    "";
    "INSERT INTO directus_collections (";
    "    collection,icon,note,display_template,hidden,singleton,";
    "    translations,archive_field,archive_app_filter,archive_value,";
    "    unarchive_value,sort_field,accountability,color,";
    "    item_duplication_fields,sort,`"group`",collapse,preview_url,";
    "    versioning,status,autosave_revision_interval";
    ")";
    "SELECT";
    "    'course_catalog_detail_api',icon,";
    "    'Gate 6.2 governed read-only detail API projection.',";
    "    '{{course_code}} - {{course_title}}',hidden,singleton,";
    "    translations,archive_field,archive_app_filter,archive_value,";
    "    unarchive_value,sort_field,accountability,color,";
    "    item_duplication_fields,sort,`"group`",collapse,preview_url,";
    "    versioning,status,autosave_revision_interval";
    "FROM directus_collections";
    "WHERE collection='course_current_catalog_api';";
    "";
    "INSERT INTO directus_permissions (";
    "    collection,action,permissions,validation,presets,fields,policy";
    ")";
    "SELECT";
    "    'course_catalog_detail_api','read',NULL,NULL,NULL,";
    "    'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes',";
    "    id";
    "FROM directus_policies";
    "WHERE name='Gate 5 Approved Reporting Read Only'";
    "  AND admin_access=false";
    "  AND app_access=false;"
)

$rehearsalSqlLines += [string[]]@(
    "";
    "DO `$gate`$";
    "DECLARE";
    "    v bigint;";
    "    fields_found text;";
    "    owner_found text;";
    "BEGIN";
    "    SELECT count(*) INTO v FROM reporting.course_catalog_detail_api;";
    "    IF v <> 964 THEN RAISE EXCEPTION 'Wrapper row count mismatch'; END IF;";
    "";
    "    SELECT count(*) INTO v";
    "    FROM (";
    "        SELECT";
    "            count(*) AS rows_found,";
    "            count(DISTINCT course_id) AS course_ids,";
    "            count(DISTINCT university_course_id) AS university_ids,";
    "            count(*) FILTER (WHERE course_goals IS NULL AND course_learning_outcomes IS NULL) AS both_null,";
    "            count(*) FILTER (WHERE (course_goals IS NULL) <> (course_learning_outcomes IS NULL)) AS partial_null";
    "        FROM reporting.course_catalog_detail_api";
    "    ) q";
    "    WHERE rows_found=964 AND course_ids=964 AND university_ids=964";
    "      AND both_null=1 AND partial_null=0;";
    "    IF v <> 1 THEN RAISE EXCEPTION 'Wrapper grain or NULL-semantics mismatch'; END IF;";
    "";
    "    SELECT string_agg(column_name,',' ORDER BY ordinal_position) INTO fields_found";
    "    FROM information_schema.columns";
    "    WHERE table_schema='reporting' AND table_name='course_catalog_detail_api';";
    "    IF fields_found <> 'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes' THEN";
    "        RAISE EXCEPTION 'Wrapper field contract mismatch';";
    "    END IF;";
    "";
    "    SELECT count(*) INTO v";
    "    FROM pg_constraint con";
    "    JOIN pg_class c ON c.oid=con.conrelid";
    "    JOIN pg_namespace n ON n.oid=c.relnamespace";
    "    WHERE n.nspname='reporting' AND c.relname='course_catalog_detail_api'";
    "      AND con.contype='p' AND pg_get_constraintdef(con.oid,true)='PRIMARY KEY (course_id)';";
    "    IF v <> 1 THEN RAISE EXCEPTION 'Wrapper primary key mismatch'; END IF;";
    "";
    "    SELECT pg_get_userbyid(c.relowner) INTO owner_found";
    "    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace";
    "    WHERE n.nspname='reporting' AND c.relname='course_catalog_detail_api';";
    "    IF owner_found <> 'air_repository_owner' THEN RAISE EXCEPTION 'Wrapper owner mismatch'; END IF;";
    "";
    "    IF NOT has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','SELECT')";
    "       OR has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','INSERT')";
    "       OR has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','UPDATE')";
    "       OR has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','DELETE')";
    "       OR has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','TRUNCATE') THEN";
    "        RAISE EXCEPTION 'Wrapper PostgreSQL privilege mismatch';";
    "    END IF;";
    "END";
    "`$gate`$;"
)

$rehearsalSqlLines += [string[]]@(
    "";
    "DO `$gate`$";
    "DECLARE v bigint; fields_found text;";
    "BEGIN";
    "    SELECT count(*) INTO v FROM directus_collections";
    "    WHERE collection='course_catalog_detail_api' AND hidden=false AND singleton=false;";
    "    IF v <> 1 THEN RAISE EXCEPTION 'Wrapper collection mismatch'; END IF;";
    "";
    "    SELECT count(*),min(p.fields) INTO v,fields_found";
    "    FROM directus_permissions p JOIN directus_policies pol ON pol.id=p.policy";
    "    WHERE p.collection='course_catalog_detail_api' AND p.action='read'";
    "      AND p.permissions IS NULL AND p.validation IS NULL AND p.presets IS NULL";
    "      AND pol.name='Gate 5 Approved Reporting Read Only'";
    "      AND pol.admin_access=false AND pol.app_access=false;";
    "    IF v <> 1 OR fields_found <> 'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes' THEN";
    "        RAISE EXCEPTION 'Wrapper read permission mismatch';";
    "    END IF;";
    "";
    "    SELECT count(*) INTO v FROM directus_permissions";
    "    WHERE collection='course_catalog_detail_api' AND action<>'read';";
    "    IF v <> 0 THEN RAISE EXCEPTION 'Unexpected wrapper write permission'; END IF;";
    "";
    "    SELECT count(*) INTO v FROM directus_fields WHERE collection='course_catalog_detail_api';";
    "    IF v <> 0 THEN RAISE EXCEPTION 'Unexpected wrapper field metadata'; END IF;";
    "";
    "    SELECT count(*) INTO v FROM directus_collections WHERE collection='course_catalog_detail';";
    "    IF v <> 0 THEN RAISE EXCEPTION 'Internal detail collection remained registered'; END IF;";
    "    SELECT count(*) INTO v FROM directus_permissions WHERE collection='course_catalog_detail';";
    "    IF v <> 0 THEN RAISE EXCEPTION 'Internal detail permission remained registered'; END IF;";
    "";
    "    SELECT count(*) INTO v FROM reporting.course_current_catalog_api;";
    "    IF v <> 966 THEN RAISE EXCEPTION 'Frozen API row count changed'; END IF;";
    "    SELECT count(*) INTO v FROM directus_permissions WHERE collection='course_current_catalog_api';";
    "    IF v <> 1 THEN RAISE EXCEPTION 'Frozen permission count changed'; END IF;";
    "END";
    "`$gate`$;"
)

$rehearsalSqlLines += [string[]]@(
    "";
    "SELECT 'PASS|GATE6_2_DETAIL_API_WRAPPER_IN_TRANSACTION';";
    "SELECT 'TX_ROWS|' || count(*) FROM reporting.course_catalog_detail_api;";
    "SELECT 'TX_FIELDS|' || count(*) FROM information_schema.columns WHERE table_schema='reporting' AND table_name='course_catalog_detail_api';";
    "SELECT 'TX_READ_PERMISSIONS|' || count(*) FROM directus_permissions WHERE collection='course_catalog_detail_api' AND action='read';";
    "SELECT 'TX_WRITE_PERMISSIONS|' || count(*) FROM directus_permissions WHERE collection='course_catalog_detail_api' AND action<>'read';";
    "SELECT 'TX_FIELD_METADATA|' || count(*) FROM directus_fields WHERE collection='course_catalog_detail_api';";
    "SELECT 'TX_INTERNAL_COLLECTION|' || count(*) FROM directus_collections WHERE collection='course_catalog_detail';";
    "SELECT 'TX_INTERNAL_PERMISSION|' || count(*) FROM directus_permissions WHERE collection='course_catalog_detail';";
    "SELECT 'TX_FROZEN_ROWS|' || count(*) FROM reporting.course_current_catalog_api;";
    "SELECT 'TX_FROZEN_PERMISSION|' || count(*) FROM directus_permissions WHERE collection='course_current_catalog_api';";
    "";
    "ROLLBACK;"
)

$rehearsalSql = $rehearsalSqlLines -join "`n"

$beginCount = [regex]::Matches($rehearsalSql,'(?im)^\s*BEGIN;\s*$').Count
$rollbackCount = [regex]::Matches($rehearsalSql,'(?im)^\s*ROLLBACK;\s*$').Count
$commitCount = [regex]::Matches($rehearsalSql,'(?im)^\s*COMMIT;\s*$').Count

$transactionContractPass = (
    $beginCount -eq 1 -and
    $rollbackCount -eq 1 -and
    $commitCount -eq 0 -and
    $rehearsalSql.TrimEnd().EndsWith("ROLLBACK;")
)

if (-not $transactionContractPass) {
    throw "STOP - rehearsal transaction contract failed. BEGIN=$beginCount ROLLBACK=$rollbackCount COMMIT=$commitCount"
}

Write-Output "PASS|REHEARSAL_SQL_TRANSACTION_CONTRACT"
Write-Output ("REHEARSAL_BEGIN_COUNT|" + $beginCount)
Write-Output ("REHEARSAL_ROLLBACK_COUNT|" + $rollbackCount)
Write-Output ("REHEARSAL_COMMIT_COUNT|" + $commitCount)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    $sqlPath,
    $rehearsalSql,
    $utf8NoBom
)

$rehearsalHashBefore = (Get-FileHash -LiteralPath $sqlPath -Algorithm SHA256).Hash.ToUpperInvariant()

$expectedTransactionMarkers = @(
    "PASS|GATE6_2_DETAIL_API_WRAPPER_IN_TRANSACTION",
    "TX_ROWS|964",
    "TX_FIELDS|8",
    "TX_READ_PERMISSIONS|1",
    "TX_WRITE_PERMISSIONS|0",
    "TX_FIELD_METADATA|0",
    "TX_INTERNAL_COLLECTION|0",
    "TX_INTERNAL_PERMISSION|0",
    "TX_FROZEN_ROWS|966",
    "TX_FROZEN_PERMISSION|1"
)

Write-Output ("PASS|SOURCE_COMMIT_ARTIFACT_FINGERPRINT|" + $sourceHash)
Write-Output ("PASS|REHEARSAL_SQL_ARTIFACT_WRITTEN|" + $sqlPath)
Write-Output ("REHEARSAL_SHA256_BEFORE|" + $rehearsalHashBefore)
Write-Output ("STATIC_BEGIN_COUNT|" + $beginCount)
Write-Output ("STATIC_ROLLBACK_COUNT|" + $rollbackCount)
Write-Output ("STATIC_COMMIT_COUNT|" + $commitCount)
Write-Output ("EXPECTED_TRANSACTION_MARKERS|" + $expectedTransactionMarkers.Count)

$mainResult = Invoke-Psql -SqlText $rehearsalSql
$mainResult.Output | Set-Content -LiteralPath $mainPath -Encoding UTF8
$mainResult.Output | ForEach-Object { Write-Output $_ }

if ($mainResult.ExitCode -ne 0) {
    throw "STOP - rollback rehearsal failed with psql exit code $($mainResult.ExitCode)."
}

foreach ($marker in $expectedTransactionMarkers) {
    if ($mainResult.Text -notmatch [regex]::Escape($marker)) {
        throw "STOP - in-transaction acceptance marker failed: $marker"
    }
}

$rehearsalHashAfter = (Get-FileHash -LiteralPath $sqlPath -Algorithm SHA256).Hash.ToUpperInvariant()

if ($rehearsalHashAfter -ne $rehearsalHashBefore) {
    throw "STOP - rehearsal SQL fingerprint changed during execution."
}

Write-Output "PASS|IN_TRANSACTION_REHEARSAL_VALIDATION"

$postResult = Invoke-Psql -SqlText $stateSql
$postResult.Output | Set-Content -LiteralPath $postPath -Encoding UTF8
$postResult.Output | ForEach-Object { Write-Output $_ }

if ($postResult.ExitCode -ne 0) {
    throw "STOP - post-rollback validation failed with psql exit code $($postResult.ExitCode)."
}

foreach ($marker in $expectedState) {
    if ($postResult.Text -notmatch [regex]::Escape($marker)) {
        throw "STOP - post-rollback restoration marker failed: $marker"
    }
}

Write-Output "PASS|POST_ROLLBACK_STATE_VALIDATION"

$postFrozen = Invoke-DirectusProbe -Uri $frozenUri
$postDetail = Invoke-DirectusProbe -Uri $detailUri
$postWrapper = Invoke-DirectusProbe -Uri $wrapperUri
$postFrozenCount = Get-AggregateCount -Probe $postFrozen

Write-Output ("POST_API|frozen_http={0}|frozen_count={1}|detail_http={2}|wrapper_http={3}" -f $postFrozen.Status,$postFrozenCount,$postDetail.Status,$postWrapper.Status)

if ($postFrozen.Status -ne 200 -or $postFrozenCount -ne "966") {
    throw "STOP - frozen Directus boundary changed after rollback rehearsal."
}

if ($postDetail.Status -ne 403) {
    throw "STOP - original detail API boundary changed after rollback rehearsal."
}

if ($postWrapper.Status -notin @(403,404)) {
    throw "STOP - rolled-back wrapper unexpectedly remained API-accessible."
}

Write-Output "PASS|POST_ROLLBACK_API_BOUNDARY_VALIDATION"

$runnerRuntimePath = $MyInvocation.MyCommand.Path
$runnerRuntimeHash = (Get-FileHash -LiteralPath $runnerRuntimePath -Algorithm SHA256).Hash.ToUpperInvariant()

$record = [ordered]@{
    task = "Gate 6.2 detail API-wrapper rollback rehearsal"
    source_commit_sha256 = $sourceHash
    runner_sha256 = $runnerRuntimeHash
    rehearsal_sql_sha256 = $rehearsalHashAfter
    clean_preflight_pass = $true
    in_transaction_pass = $true
    post_rollback_state_pass = $true
    post_rollback_api_pass = $true
    api_test_performed_in_transaction = $false
    wrapper_rows_rehearsed = 964
    wrapper_fields_rehearsed = 8
    persistent_postgresql_mutation = $false
    persistent_directus_mutation = $false
    middleware_mutated = $false
    department_in_scope = $false
    business_values_printed = $false
    token_printed = $false
    created_utc = [DateTime]::UtcNow.ToString("o")
}

$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordPath -Encoding UTF8

$evidenceFiles = @(
    $runnerRuntimePath,
    $sqlPath,
    $mainPath,
    $postPath,
    $recordPath
)

$checksumLines = foreach ($file in $evidenceFiles) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "STOP - expected evidence file missing: $file"
    }

    "{0} *{1}" -f (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToUpperInvariant(),(Split-Path -Leaf $file)
}

$manifestPath = Join-Path $evidenceDir "SHA256SUMS.txt"
$checksumLines | Set-Content -LiteralPath $manifestPath -Encoding ASCII

$token = $null
$apiHeaders = $null

$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()

Write-Output "PASS|EVIDENCE_PACKAGE_WRITTEN"
Write-Output ("RUNNER_SHA256|" + $runnerRuntimeHash)
Write-Output ("REHEARSAL_SHA256_AFTER|" + $rehearsalHashAfter)
Write-Output ("SHA256_MANIFEST|" + $manifestPath)
Write-Output ("SHA256_MANIFEST_HASH|" + $manifestHash)
Write-Output ("EVIDENCE_DIRECTORY|" + $evidenceDir)
Write-Output "API_TEST_PERFORMED_IN_TRANSACTION|false"
Write-Output "DIRECTUS_PERSISTENT_MUTATION|false"
Write-Output "POSTGRESQL_PERSISTENT_MUTATION|false"
Write-Output "MIDDLEWARE_MUTATED|false"
Write-Output "DEPARTMENT_IN_SCOPE|false"
Write-Output "BUSINESS_VALUES_PRINTED|false"
Write-Output "TOKEN_PRINTED|false"
Write-Output "PASS|GATE6_2_DETAIL_API_WRAPPER_ROLLBACK_REHEARSAL"
Write-Output "NEXT_READINESS|PREPARE_SEPARATELY_FINGERPRINTED_COMMIT_ARTIFACT"
