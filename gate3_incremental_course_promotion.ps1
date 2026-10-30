$ErrorActionPreference = 'Stop'

$SqlFile = '.\gate3_incremental_course_promotion.sql'
$EvidenceFile = '.\gate3_catalog_incremental_course_promotion_reconciliation.csv'

$ExpectedSha256 = '285a468d2e4156adece2a5a97f431b9b98c43cbe66eaa77d53dc1850e4f6a668'
$ExpectedBatch = '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'
$ExpectedFingerprint = 'c28dfafdcf5ec41e4f3a0fc2992f90ebac8c8bbdf75c55526d8a6a14cccc65f9'
$ExpectedStagingTable = 'staging.raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd'

Write-Host ''
Write-Host 'Gate 3 Incremental Course Promotion' -ForegroundColor Cyan
Write-Host '-----------------------------------'
Write-Host ''

#
# 1. Verify SQL file exists.
#
if (-not (Test-Path -LiteralPath $SqlFile -PathType Leaf)) {
    throw "SQL file not found: $SqlFile"
}

#
# 2. Read SQL exactly as UTF-8 text.
#
$sql = Get-Content -LiteralPath $SqlFile -Raw -Encoding UTF8

#
# 3. Verify SHA-256 before allowing execution.
#
$ActualSha256 = (
    Get-FileHash -LiteralPath $SqlFile -Algorithm SHA256
).Hash.ToLowerInvariant()

if ($ActualSha256 -ne $ExpectedSha256) {
    throw @"
SQL SHA-256 validation failed.

Expected:
$ExpectedSha256

Actual:
$ActualSha256

The SQL file has changed. Promotion was NOT executed.
"@
}

#
# 4. Perform additional structural safety checks.
#
$lines = @(
    Get-Content -LiteralPath $SqlFile -Encoding UTF8
)

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

if (-not $sql.Contains($ExpectedBatch)) {
    throw 'SQL validation failed: expected import batch UUID is missing.'
}

if (-not $sql.Contains($ExpectedFingerprint)) {
    throw 'SQL validation failed: expected source fingerprint is missing.'
}

if (-not $sql.Contains($ExpectedStagingTable)) {
    throw 'SQL validation failed: expected staging table is missing.'
}

if ($sql -notmatch 'component_id\s*=\s*52') {
    throw 'SQL validation failed: component 52 check is missing.'
}

if (-not $sql.Contains('INSERT INTO core.course')) {
    throw 'SQL validation failed: Course INSERT logic is missing.'
}

if (-not $sql.Contains('UPDATE core.course c')) {
    throw 'SQL validation failed: Course UPDATE logic is missing.'
}

if (
    -not $sql.Contains('v_insert = 2') -or
    -not $sql.Contains('v_update = 3') -or
    -not $sql.Contains('v_unchanged = 961')
) {
    throw 'SQL validation failed: expected first-run reconciliation checks are missing.'
}

if (
    -not $sql.Contains('v_insert = 0') -or
    -not $sql.Contains('v_update = 0') -or
    -not $sql.Contains('v_unchanged = 966')
) {
    throw 'SQL validation failed: expected idempotency checks are missing.'
}

if (-not $sql.Contains('One or more UPDATE Course UUIDs changed')) {
    throw 'SQL validation failed: UUID-preservation check is missing.'
}

if (-not $sql.Contains('The 961 unchanged Course rows were not left untouched')) {
    throw 'SQL validation failed: unchanged-row protection check is missing.'
}

if (
    -not $sql.Contains('DO $promote$') -or
    -not $sql.Contains('$promote$;')
) {
    throw 'SQL validation failed: promotion transaction block is incomplete.'
}

if (
    -not $sql.Contains('DO $post$') -or
    -not $sql.Contains('$post$;')
) {
    throw 'SQL validation failed: post-promotion validation block is incomplete.'
}

if ($sql -match '&(?:gt|lt|amp|quot);') {
    throw 'SQL validation failed: HTML entities were detected.'
}


Write-Host 'SQL integrity validation: PASS' -ForegroundColor Green
Write-Host "SHA-256: $ActualSha256"
Write-Host ''
Write-Host 'Executing controlled PostgreSQL transaction...' -ForegroundColor Yellow
Write-Host ''

#
# 5. Execute SQL through stdin.
#
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

#
# 6. PostgreSQL must return success.
#
if ($PsqlExitCode -ne 0) {
    throw @"
Controlled incremental Course promotion failed.

psql exit code: $PsqlExitCode

PostgreSQL should have rolled back the transaction because
ON_ERROR_STOP=1 was enabled.

Review the PostgreSQL error above before doing anything else.
"@
}

#
# 7. Extract only the reconciliation CSV.
#
$rows = @(
    $result |
        Where-Object {
            $_ -match '^(disposition|INSERT|UPDATE|UNCHANGED|CROSSWALK_REVIEW|IDENTITY_CONFLICT|DUPLICATE|EXCEPTION),'
        }
)

if ($rows.Count -ne 8) {
    throw "Expected one CSV header plus seven reconciliation rows; received $($rows.Count) lines."
}

#
# 8. Parse reconciliation evidence.
#
$parsed = @(
    $rows |
        ConvertFrom-Csv
)

if ($parsed.Count -ne 7) {
    throw "Expected seven parsed reconciliation rows; received $($parsed.Count)."
}

#
# 9. Every reconciliation row must report PASS.
#
$failed = @(
    $parsed |
        Where-Object {
            $_.post_promotion_reconciliation -ne 'PASS'
        }
)

if ($failed.Count -gt 0) {
    throw 'Post-promotion reconciliation did not return PASS for all seven dispositions.'
}

#
# 10. Verify final disposition counts.
#
$expectedCounts = @{
    INSERT            = 0
    UPDATE            = 0
    UNCHANGED         = 966
    CROSSWALK_REVIEW  = 0
    IDENTITY_CONFLICT = 0
    DUPLICATE         = 0
    EXCEPTION         = 0
}

foreach ($disposition in $expectedCounts.Keys) {

    $row = @(
        $parsed |
            Where-Object {
                $_.disposition -eq $disposition
            }
    )

    if ($row.Count -ne 1) {
        throw "Expected exactly one reconciliation row for $disposition."
    }

    if ([int64]$row[0].row_count -ne $expectedCounts[$disposition]) {
        throw "Unexpected $disposition count: $($row[0].row_count)."
    }
}

#
# 11. Verify common post-promotion metrics.
#
$reference = $parsed[0]

if ([int64]$reference.current_core_course_rows -ne 966) {
    throw "Expected 966 current WW_CATALOG Courses; received $($reference.current_core_course_rows)."
}

if ([int64]$reference.preserved_update_uuids -ne 3) {
    throw "Expected 3 preserved UPDATE UUIDs; received $($reference.preserved_update_uuids)."
}

if ([int64]$reference.new_batch_lineage_rows -ne 5) {
    throw "Expected 5 new-batch lineage rows; received $($reference.new_batch_lineage_rows)."
}

if ([int64]$reference.untouched_prior_lineage_rows -ne 961) {
    throw "Expected 961 untouched prior-lineage rows; received $($reference.untouched_prior_lineage_rows)."
}

#
# 12. Determine whether this was first promotion or idempotency rerun.
#
$InsertedThisRun = [int64]$reference.inserted_this_run
$UpdatedThisRun = [int64]$reference.updated_this_run
$ExistingBefore = [int64]$reference.existing_before

$FirstRunPass = (
    $InsertedThisRun -eq 2 -and
    $UpdatedThisRun -eq 3 -and
    $ExistingBefore -eq 964
)

$RerunPass = (
    $InsertedThisRun -eq 0 -and
    $UpdatedThisRun -eq 0 -and
    $ExistingBefore -eq 966
)

if (-not ($FirstRunPass -or $RerunPass)) {
    throw @"
Unexpected promotion metrics.

inserted_this_run = $InsertedThisRun
updated_this_run  = $UpdatedThisRun
existing_before   = $ExistingBefore
"@
}

#
# 13. Save reconciliation evidence.
#
$rows |
    Set-Content `
        -LiteralPath $EvidenceFile `
        -Encoding UTF8

#
# 14. Display final evidence.
#
Write-Host ''
Write-Host 'Gate 3 incremental Course promotion: PASS' -ForegroundColor Green
Write-Host ''

$parsed |
    Format-Table `
        disposition,
        row_count,
        inserted_this_run,
        updated_this_run,
        existing_before,
        current_core_course_rows,
        preserved_update_uuids,
        new_batch_lineage_rows,
        untouched_prior_lineage_rows,
        post_promotion_reconciliation `
        -AutoSize

Write-Host ''

if ($FirstRunPass) {
    Write-Host 'Execution type: FIRST CONTROLLED PROMOTION' -ForegroundColor Green
}
else {
    Write-Host 'Execution type: IDEMPOTENCY RERUN' -ForegroundColor Green
}

Write-Host "Evidence: $EvidenceFile"
Write-Host "SQL SHA-256: $ActualSha256"
