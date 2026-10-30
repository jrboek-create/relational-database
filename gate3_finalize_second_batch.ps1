$ErrorActionPreference = 'Stop'

$SqlFile = '.\gate3_finalize_second_batch.sql'
$EvidenceFile = '.\gate3_catalog_incremental_batch_finalization.csv'

if (-not (Test-Path -LiteralPath $SqlFile -PathType Leaf)) {
    throw "SQL file not found: $SqlFile"
}

$sql = Get-Content -LiteralPath $SqlFile -Raw -Encoding UTF8

$lines = @(Get-Content -LiteralPath $SqlFile -Encoding UTF8)

$substantive = @(
    $lines |
        Where-Object {
            $_.Trim() -ne '' -and
            -not $_.Trim().StartsWith('--')
        }
)

if ($substantive.Count -eq 0) {
    throw 'SQL file contains no executable SQL.'
}

if ($substantive[0].Trim() -ne 'BEGIN;') {
    throw 'SQL validation failed: first substantive statement is not BEGIN;'
}

if ($substantive[-1].Trim() -ne 'COMMIT;') {
    throw 'SQL validation failed: last substantive statement is not COMMIT;'
}

if (-not $sql.Contains('53e0ae11-6a25-4f0a-9beb-814c8c3d1946')) {
    throw 'SQL validation failed: expected batch UUID is missing.'
}

if (-not $sql.Contains('component_id = 52')) {
    throw 'SQL validation failed: component 52 check is missing.'
}

if (-not $sql.Contains('c28dfafdcf5ec41e4f3a0fc2992f90ebac8c8bbdf75c55526d8a6a14cccc65f9')) {
    throw 'SQL validation failed: expected fingerprint is missing.'
}

if (-not $sql.Contains('raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd')) {
    throw 'SQL validation failed: expected staging table is missing.'
}

if (-not $sql.Contains("SET batch_status = 'PROMOTED'")) {
    throw 'SQL validation failed: core finalization logic is missing.'
}

if (-not $sql.Contains("status = 'STAGED'")) {
    throw 'SQL validation failed: staging finalization logic is missing.'
}

if (-not $sql.Contains('finalization_reconciliation')) {
    throw 'SQL validation failed: final reconciliation is missing.'
}

if ($sql -match '&(?:gt|lt|amp|quot);') {
    throw 'SQL validation failed: HTML entities detected.'
}

if ($sql -match '<br\s*/?>') {
    throw 'SQL validation failed: literal HTML BR tags detected.'
}

Write-Host ''
Write-Host 'Gate 3 Second Batch Finalization' -ForegroundColor Cyan
Write-Host '--------------------------------'
Write-Host ''
Write-Host 'SQL validation: PASS' -ForegroundColor Green
Write-Host ''

$result = @(
    $sql |
        docker compose exec -T database `
            psql `
            -X `
            -U directus_repository `
            -d directus_repository `
            -P pager=off `
            -P footer=off `
            -v ON_ERROR_STOP=1 `
            -q `
            --csv
)

$PsqlExitCode = $LASTEXITCODE

if ($PsqlExitCode -ne 0) {
    throw "Gate 3 batch finalization failed. PostgreSQL exit code: $PsqlExitCode"
}

$rows = @(
    $result |
        Where-Object {
            $_ -match '^(batch_id|53e0ae11-6a25-4f0a-9beb-814c8c3d1946),'
        }
)

if ($rows.Count -ne 2) {
    throw "Expected one CSV header and one finalization row; received $($rows.Count) lines."
}

$parsed = @(
    $rows |
        ConvertFrom-Csv
)

if ($parsed.Count -ne 1) {
    throw "Expected one finalization result; received $($parsed.Count)."
}

$r = $parsed[0]

if ($r.finalization_reconciliation -ne 'PASS') {
    throw 'Post-finalization reconciliation did not PASS.'
}

if ($r.staging_status -ne 'STAGED') {
    throw "Unexpected staging status: $($r.staging_status)"
}

if ($r.core_batch_status -ne 'PROMOTED') {
    throw "Unexpected core batch status: $($r.core_batch_status)"
}

if ($r.component_status -ne 'SUCCEEDED') {
    throw "Unexpected component status: $($r.component_status)"
}

if ([int64]$r.staged_rows -ne 966) {
    throw "Unexpected staged row count: $($r.staged_rows)"
}

if ([int64]$r.current_course_rows -ne 966) {
    throw "Unexpected current Course count: $($r.current_course_rows)"
}

if ([int64]$r.new_batch_lineage_rows -ne 5) {
    throw "Unexpected new-batch lineage count: $($r.new_batch_lineage_rows)"
}

if ([int64]$r.prior_batch_lineage_rows -ne 961) {
    throw "Unexpected prior-batch lineage count: $($r.prior_batch_lineage_rows)"
}

$rows |
    Set-Content `
        -LiteralPath $EvidenceFile `
        -Encoding UTF8

Write-Host 'Gate 3 second batch finalization: PASS' -ForegroundColor Green
Write-Host ''

$parsed |
    Format-Table `
        batch_id,
        staging_status,
        component_status,
        core_batch_status,
        current_course_rows,
        new_batch_lineage_rows,
        prior_batch_lineage_rows,
        finalization_reconciliation `
        -AutoSize

Write-Host ''
Write-Host "Evidence: $EvidenceFile"