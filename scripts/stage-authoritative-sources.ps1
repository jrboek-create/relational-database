Invoke-RepositorySql @"
UPDATE staging._import_batches
SET completed_at=now(),
    status='$FinalStatus',
    failure_count=$($Failures.Count)
WHERE batch_id='$BatchId';
"@ | Out-Null
 
# -------------------------------------------------------------------
# CSV report exports
# -------------------------------------------------------------------
 
function Export-DatabaseReport {
    param([string]$Query,[string]$Path)
 
    $Output = @(
        & docker compose exec -T $DatabaseService `
            psql -X -q -U $DatabaseUser -d $DatabaseName `
            -c "\copy ($Query) TO STDOUT WITH (FORMAT CSV, HEADER TRUE)" `
            2>&1
    )
 
    if ($LASTEXITCODE -ne 0) {
        throw "Report export failed: $Path`n$($Output -join "`n")"
    }
 
    $Output | Set-Content -LiteralPath $Path -Encoding UTF8
}
 
Export-DatabaseReport `
    "SELECT * FROM staging._source_components WHERE batch_id='$BatchId' ORDER BY relative_path,source_component" `
    (Join-Path $BatchDir 'import_reconciliation.csv')
 
Export-DatabaseReport `
    "SELECT * FROM staging._field_profile WHERE batch_id='$BatchId' ORDER BY staging_table,field_name" `
    (Join-Path $BatchDir 'field_profile.csv')
 
Export-DatabaseReport `
    "SELECT * FROM staging._validation_exceptions WHERE batch_id='$BatchId' ORDER BY severity,rule_code,staging_table,source_row_number" `
    (Join-Path $BatchDir 'validation_exceptions.csv')
 
Export-DatabaseReport `
    "SELECT * FROM staging._record_status WHERE batch_id='$BatchId' ORDER BY validation_status DESC,staging_table,source_row_number" `
    (Join-Path $BatchDir 'record_status.csv')
 
if ($Failures.Count -gt 0) {
    $Failures |
        Set-Content (Join-Path $BatchDir 'import_failures.txt') -Encoding UTF8
}
 
Write-Host "`nBatch ID : $BatchId" -ForegroundColor Cyan
Write-Host "Status   : $FinalStatus" -ForegroundColor Cyan
Write-Host "Reports  : $BatchDir" -ForegroundColor Cyan
 
if ($Failures.Count -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    $Failures | ForEach-Object {
        Write-Host " - $_" -ForegroundColor Red
    }
 
    throw "Import completed with $($Failures.Count) failure(s)."
}
 