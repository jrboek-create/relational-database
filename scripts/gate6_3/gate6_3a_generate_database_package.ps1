# AIR Course Development Master Hub
# Gate 6.3A - Generate and validate database package only (NO DATABASE MUTATION)
# Windows PowerShell 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\Directus\relational-repository'
Set-Location -LiteralPath $Root
$RunId = Get-Date -Format 'yyyyMMdd_HHmmss'
$SqlDir = Join-Path $Root 'sql\gate6_3'
$EvidenceDir = Join-Path $Root ("evidence\gate6_3\{0}" -f $RunId)
$SourcePath = Join-Path $Root 'imports_hold\ER_SR_1CAT_UNIV_MASTER_DETAIL_1512061533.xlsx'
$ExpectedSourceHash = '2B4B77F3D00BC18EDEECFA5C6342B2E22A67699886FC60B94325908517F270AD'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$ExpectedApplicationHashes = [ordered]@{
  'middleware\src\server.js' = 'B7661752231F0F79B2A36E5D5B97AC85ECFC5A419DAC20E086399FE96624198F'
  'middleware\contracts\api-courses-v1.json' = '68A2D51409AD1D75E7FA516A3C9ACE60CFDA0A715D0F99DAA1F5F4A845624C87'
  'ui\app.js' = 'B3E288722FC1E388F0FEBA4BACABDC4CFF8E9DEEB353EE459969203F6D760506'
  'ui\index.html' = 'A11924AB912123D789C2977F41C7B53255F468044C409D103F58F0F053974E1D'
}

function Write-Utf8Lines {
  param([string]$Path,[string[]]$Lines)
  $parent = [IO.Path]::GetDirectoryName($Path)
  if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
  [IO.File]::WriteAllLines($Path,$Lines,$Utf8)
}

function Normalize-Text {
  param($Value)
  if ($null -eq $Value) { return '' }
  return ([string]$Value).Trim()
}

function Normalize-Code {
  param($Value)
  return ((((Normalize-Text $Value) -replace '\s+',' ').Trim()).ToUpperInvariant())
}

function Sql-Literal {
  param($Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 'NULL' }
  return "'" + ([string]$Value).Replace("'","''") + "'"
}

function Invoke-ReadOnlySql {
  param([string]$Sql)
  $output = @(& docker compose exec -T database psql -X -U directus_repository -d directus_repository -A -t -F '|' -P pager=off -v ON_ERROR_STOP=1 -c $Sql 2>&1)
  if ($LASTEXITCODE -ne 0) { throw ("READ_ONLY_SQL_FAILED|" + ($output -join ' ')) }
  return @($output)
}

Write-Output 'GATE6_3A_PACKAGE_GENERATION_BEGIN'
Write-Output 'MODE|artifact-generation-only'
Write-Output 'DATABASE_MUTATION|false'
Write-Output 'APPLICATION_MUTATION|false'

# Immutable file preflight
if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "SOURCE_MISSING|$SourcePath" }
$sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($sourceHash -ne $ExpectedSourceHash) { throw "SOURCE_HASH_FAIL|expected=$ExpectedSourceHash|actual=$sourceHash" }
Write-Output 'PREFLIGHT_SOURCE_HASH|PASS'

foreach ($relativePath in $ExpectedApplicationHashes.Keys) {
  $fullPath = Join-Path $Root $relativePath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "APPLICATION_FILE_MISSING|$relativePath" }
  $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToUpperInvariant()
  if ($actual -ne $ExpectedApplicationHashes[$relativePath]) { throw "APPLICATION_HASH_FAIL|$relativePath|expected=$($ExpectedApplicationHashes[$relativePath])|actual=$actual" }
}
Write-Output 'PREFLIGHT_APPLICATION_HASHES|PASS'

# Read-only database state preflight
$preflightSql = @(
  "SELECT 'CATALOG|'||count(*) FROM reporting.course_current_catalog;",
  "SELECT 'CATALOG_API|'||count(*) FROM reporting.course_current_catalog_api;",
  "SELECT 'DETAIL|'||count(*) FROM reporting.course_catalog_detail;",
  "SELECT 'DETAIL_API|'||count(*) FROM reporting.course_catalog_detail_api;",
  "SELECT 'COLLEGE|'||count(*) FROM reporting.course_catalog_detail WHERE college_name IS NOT NULL;",
  "SELECT 'RECON|'||CASE WHEN to_regclass('reporting.course_organization_reconciliation') IS NULL THEN 'ABSENT' ELSE 'PRESENT' END;",
  "SELECT 'CATALOG_NEW_COLUMNS|'||count(*) FROM information_schema.columns WHERE table_schema='reporting' AND table_name='course_current_catalog_api' AND column_name IN ('college_name','department_name');",
  "SELECT 'DETAIL_NEW_COLUMNS|'||count(*) FROM information_schema.columns WHERE table_schema='reporting' AND table_name='course_catalog_detail_api' AND column_name='department_name';"
) -join [Environment]::NewLine
$preflightText = (Invoke-ReadOnlySql $preflightSql) -join "`n"
foreach ($required in @('CATALOG|966','CATALOG_API|966','DETAIL|964','DETAIL_API|964','COLLEGE|964','RECON|ABSENT','CATALOG_NEW_COLUMNS|0','DETAIL_NEW_COLUMNS|0')) {
  if ($preflightText -notmatch [regex]::Escape($required)) { throw "DATABASE_PREFLIGHT_FAIL|missing=$required" }
}
Write-Output 'PREFLIGHT_DATABASE|PASS'

# Read authoritative workbook read-only
$excel=$null; $workbook=$null; $worksheet=$null; $usedRange=$null; $sourceById=@{}
try {
  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $workbook = $excel.Workbooks.Open($SourcePath,0,$true)
  $worksheet = $workbook.Worksheets.Item('sheet1')
  $usedRange = $worksheet.UsedRange
  $values = $usedRange.Value2
  $headers = @{}
  for ($column=1; $column -le $usedRange.Columns.Count; $column++) {
    $header = Normalize-Text $values[1,$column]
    if ($header) { $headers[$header]=$column }
  }
  foreach ($requiredHeader in @('Univ Course ID','Univ Subject','Univ Catalog Nbr','WW Acad Org','WW Department Name')) {
    if (-not $headers.ContainsKey($requiredHeader)) { throw "SOURCE_COLUMN_MISSING|$requiredHeader" }
  }
  for ($row=2; $row -le $usedRange.Rows.Count; $row++) {
    $id = Normalize-Text $values[$row,$headers['Univ Course ID']]
    if (-not $id) { continue }
    if ($sourceById.ContainsKey($id)) { throw "SOURCE_DUPLICATE_ID|$id" }
    $subject = Normalize-Text $values[$row,$headers['Univ Subject']]
    $catalogNumber = Normalize-Text $values[$row,$headers['Univ Catalog Nbr']]
    $sourceById[$id] = [pscustomobject]@{
      Code = Normalize-Code "$subject $catalogNumber"
      Org = Normalize-Text $values[$row,$headers['WW Acad Org']]
      Department = Normalize-Text $values[$row,$headers['WW Department Name']]
      Row = $row
    }
  }
}
finally {
  if ($workbook) { try { $workbook.Close($false) } catch {} }
  foreach ($object in @($usedRange,$worksheet,$workbook)) { if ($object) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($object) } catch {} } }
  if ($excel) { try { $excel.Quit() } catch {}; try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel) } catch {} }
  [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}
if ($sourceById.Count -ne 2582) { throw "SOURCE_DISTINCT_ID_FAIL|expected=2582|actual=$($sourceById.Count)" }
Write-Output 'PREFLIGHT_WORKBOOK|PASS'

# Build 966-row reconciliation in memory
$catalogSql = "SELECT university_course_id,course_code FROM reporting.course_current_catalog ORDER BY university_course_id;"
$catalogLines = @(Invoke-ReadOnlySql $catalogSql)
$records=@(); $counts=@{}
foreach ($line in $catalogLines) {
  $text=([string]$line).Trim(); if (-not $text) { continue }
  $parts=$text -split '\|',2; if ($parts.Count -ne 2) { continue }
  $id=Normalize-Text $parts[0]; $code=Normalize-Code $parts[1]
  $org=$null; $sourceDepartment=$null; $department=$null; $sourceRow=$null
  if ($code -in @('TSTG 900','TSTG 901')) { $status='CONTROLLED_TEST' }
  elseif (-not $sourceById.ContainsKey($id)) { $status='UNMATCHED_SOURCE' }
  else {
    $source=$sourceById[$id]
    if ($source.Org) { $org=$source.Org }
    if ($source.Department) { $sourceDepartment=$source.Department }
    $sourceRow=$source.Row
    if ($source.Code -eq $code) {
      if ($sourceDepartment) { $status='EXACT_ID_CODE_DEPARTMENT'; $department=$sourceDepartment }
      else { $status='EXACT_ID_CODE_BLANK' }
    } else {
      if ($sourceDepartment) { $status='CODE_MISMATCH_DEPARTMENT_HOLD' }
      else { $status='CODE_MISMATCH_BLANK_HOLD' }
    }
  }
  if (-not $counts.ContainsKey($status)) { $counts[$status]=0 }; $counts[$status]++
  $records += [pscustomobject]@{university_course_id=$id;validated_course_code=$code;ww_acad_org=$org;source_department_name=$sourceDepartment;department_name=$department;reconciliation_status=$status;source_file_name='ER_SR_1CAT_UNIV_MASTER_DETAIL_1512061533.xlsx';source_sha256=$ExpectedSourceHash;source_row_number=$sourceRow}
}
$expected=[ordered]@{EXACT_ID_CODE_DEPARTMENT=827;EXACT_ID_CODE_BLANK=98;CODE_MISMATCH_DEPARTMENT_HOLD=10;CODE_MISMATCH_BLANK_HOLD=3;UNMATCHED_SOURCE=26;CONTROLLED_TEST=2}
if ($records.Count -ne 966) { throw "RECON_TOTAL_FAIL|expected=966|actual=$($records.Count)" }
foreach ($name in $expected.Keys) { $actual=0; if ($counts.ContainsKey($name)) {$actual=$counts[$name]}; Write-Output "RECON_STATUS|$name|$actual"; if ($actual -ne $expected[$name]) { throw "RECON_COUNT_FAIL|$name|expected=$($expected[$name])|actual=$actual" } }
Write-Output 'PREFLIGHT_RECONCILIATION|PASS'

# Create artifact directories only after every preflight passes
[IO.Directory]::CreateDirectory($SqlDir) | Out-Null
[IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null
$CsvPath = Join-Path $EvidenceDir 'course_organization_reconciliation.csv'
$records | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8

# SQL VALUES generated from validated records
$valueLines=@()
foreach ($r in $records) {
  $sourceRowSql = if ($null -eq $r.source_row_number) {'NULL'} else {[string]$r.source_row_number}
  $valueLines += ('({0},{1},{2},{3},{4},{5},{6},{7},{8})' -f (Sql-Literal $r.university_course_id),(Sql-Literal $r.validated_course_code),(Sql-Literal $r.ww_acad_org),(Sql-Literal $r.source_department_name),(Sql-Literal $r.department_name),(Sql-Literal $r.reconciliation_status),(Sql-Literal $r.source_file_name),(Sql-Literal $r.source_sha256),$sourceRowSql)
}

$backupSchema=('gate6_3_backup_'+$RunId).ToLowerInvariant()
$CommitPath=Join-Path $SqlDir ("gate6_3_database_commit_{0}.sql" -f $RunId)
$RollbackPath=Join-Path $SqlDir ("gate6_3_database_rollback_{0}.sql" -f $RunId)
$RefreshPath=Join-Path $SqlDir 'gate6_3_refresh_api_tables.sql'

$commit=@('BEGIN;','SET ROLE air_repository_owner;',("CREATE SCHEMA {0} AUTHORIZATION air_repository_owner;" -f $backupSchema),("CREATE TABLE {0}.course_current_catalog_api AS TABLE reporting.course_current_catalog_api;" -f $backupSchema),("CREATE TABLE {0}.course_catalog_detail_api AS TABLE reporting.course_catalog_detail_api;" -f $backupSchema),'CREATE TABLE reporting.course_organization_reconciliation (',' university_course_id text PRIMARY KEY,',' validated_course_code text NOT NULL,',' ww_acad_org text,',' source_department_name text,',' department_name text,',' reconciliation_status text NOT NULL,',' source_file_name text NOT NULL,',' source_sha256 text NOT NULL,',' source_row_number bigint,',' created_at timestamptz NOT NULL DEFAULT clock_timestamp(),',(" CHECK (source_sha256='{0}')," -f $ExpectedSourceHash)," CHECK (reconciliation_status IN ('EXACT_ID_CODE_DEPARTMENT','EXACT_ID_CODE_BLANK','CODE_MISMATCH_DEPARTMENT_HOLD','CODE_MISMATCH_BLANK_HOLD','UNMATCHED_SOURCE','CONTROLLED_TEST')),"," CHECK ((reconciliation_status='EXACT_ID_CODE_DEPARTMENT' AND department_name IS NOT NULL AND btrim(department_name)<>'') OR (reconciliation_status<>'EXACT_ID_CODE_DEPARTMENT' AND department_name IS NULL))",');','INSERT INTO reporting.course_organization_reconciliation (university_course_id,validated_course_code,ww_acad_org,source_department_name,department_name,reconciliation_status,source_file_name,source_sha256,source_row_number) VALUES')
for ($i=0; $i -lt $valueLines.Count; $i++) { $commit += $valueLines[$i] + $(if ($i -eq $valueLines.Count-1) {';'} else {','}) }
$commit += @('ALTER TABLE reporting.course_current_catalog_api ADD COLUMN college_name text;','ALTER TABLE reporting.course_current_catalog_api ADD COLUMN department_name text;','ALTER TABLE reporting.course_catalog_detail_api ADD COLUMN department_name text;','DELETE FROM reporting.course_current_catalog_api;','INSERT INTO reporting.course_current_catalog_api (course_id,university_course_id,course_code,course_title,source_system_code,report_refresh_run_id,report_as_of_utc,college_name,department_name) SELECT c.course_id,c.university_course_id,c.course_code,c.course_title,c.source_system_code,c.report_refresh_run_id,c.report_as_of_utc,d.college_name,r.department_name FROM reporting.course_current_catalog c LEFT JOIN reporting.course_catalog_detail d ON d.course_id=c.course_id LEFT JOIN reporting.course_organization_reconciliation r ON r.university_course_id=c.university_course_id;','DELETE FROM reporting.course_catalog_detail_api;','INSERT INTO reporting.course_catalog_detail_api (course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes,department_name) SELECT d.course_id,d.university_course_id,d.course_code,d.course_title,d.college_name,d.course_description,d.course_goals,d.course_learning_outcomes,r.department_name FROM reporting.course_catalog_detail d LEFT JOIN reporting.course_organization_reconciliation r ON r.university_course_id=d.university_course_id;','DO $$','BEGIN'," IF (SELECT count(*) FROM reporting.course_organization_reconciliation)<>966 THEN RAISE EXCEPTION 'reconciliation count failed'; END IF;"," IF (SELECT count(*) FROM reporting.course_organization_reconciliation WHERE department_name IS NOT NULL)<>827 THEN RAISE EXCEPTION 'department count failed'; END IF;"," IF (SELECT count(*) FROM reporting.course_current_catalog_api)<>966 THEN RAISE EXCEPTION 'catalog API count failed'; END IF;"," IF (SELECT count(*) FROM reporting.course_current_catalog_api WHERE college_name IS NOT NULL)<>964 THEN RAISE EXCEPTION 'college count failed'; END IF;"," IF (SELECT count(*) FROM reporting.course_current_catalog_api WHERE department_name IS NOT NULL)<>827 THEN RAISE EXCEPTION 'catalog department count failed'; END IF;"," IF (SELECT count(*) FROM reporting.course_catalog_detail_api)<>964 THEN RAISE EXCEPTION 'detail API count failed'; END IF;"," IF (SELECT count(*) FROM reporting.course_catalog_detail_api WHERE department_name IS NOT NULL)<>827 THEN RAISE EXCEPTION 'detail department count failed'; END IF;",'END','$$;','ANALYZE reporting.course_organization_reconciliation;','ANALYZE reporting.course_current_catalog_api;','ANALYZE reporting.course_catalog_detail_api;','COMMIT;')
Write-Utf8Lines $CommitPath $commit

$refresh=@('BEGIN;','SET ROLE air_repository_owner;','ALTER TABLE reporting.course_current_catalog_api ADD COLUMN IF NOT EXISTS college_name text;','ALTER TABLE reporting.course_current_catalog_api ADD COLUMN IF NOT EXISTS department_name text;','ALTER TABLE reporting.course_catalog_detail_api ADD COLUMN IF NOT EXISTS department_name text;','DELETE FROM reporting.course_current_catalog_api;','INSERT INTO reporting.course_current_catalog_api (course_id,university_course_id,course_code,course_title,source_system_code,report_refresh_run_id,report_as_of_utc,college_name,department_name) SELECT c.course_id,c.university_course_id,c.course_code,c.course_title,c.source_system_code,c.report_refresh_run_id,c.report_as_of_utc,d.college_name,r.department_name FROM reporting.course_current_catalog c LEFT JOIN reporting.course_catalog_detail d ON d.course_id=c.course_id LEFT JOIN reporting.course_organization_reconciliation r ON r.university_course_id=c.university_course_id;','DELETE FROM reporting.course_catalog_detail_api;','INSERT INTO reporting.course_catalog_detail_api (course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes,department_name) SELECT d.course_id,d.university_course_id,d.course_code,d.course_title,d.college_name,d.course_description,d.course_goals,d.course_learning_outcomes,r.department_name FROM reporting.course_catalog_detail d LEFT JOIN reporting.course_organization_reconciliation r ON r.university_course_id=d.university_course_id;','COMMIT;')
Write-Utf8Lines $RefreshPath $refresh

$rollback=@('BEGIN;','SET ROLE air_repository_owner;','DELETE FROM reporting.course_current_catalog_api;',("INSERT INTO reporting.course_current_catalog_api (course_id,university_course_id,course_code,course_title,source_system_code,report_refresh_run_id,report_as_of_utc) SELECT course_id,university_course_id,course_code,course_title,source_system_code,report_refresh_run_id,report_as_of_utc FROM {0}.course_current_catalog_api;" -f $backupSchema),'ALTER TABLE reporting.course_current_catalog_api DROP COLUMN IF EXISTS college_name;','ALTER TABLE reporting.course_current_catalog_api DROP COLUMN IF EXISTS department_name;','DELETE FROM reporting.course_catalog_detail_api;',("INSERT INTO reporting.course_catalog_detail_api (course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes) SELECT course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes FROM {0}.course_catalog_detail_api;" -f $backupSchema),'ALTER TABLE reporting.course_catalog_detail_api DROP COLUMN IF EXISTS department_name;','DROP TABLE IF EXISTS reporting.course_organization_reconciliation;','COMMIT;')
Write-Utf8Lines $RollbackPath $rollback

# Static artifact validation only; SQL is NOT executed
$requiredCommitMarkers=@('BEGIN;','CREATE TABLE reporting.course_organization_reconciliation','ALTER TABLE reporting.course_current_catalog_api ADD COLUMN college_name text;','ALTER TABLE reporting.course_catalog_detail_api ADD COLUMN department_name text;','COMMIT;')
$commitText=[IO.File]::ReadAllText($CommitPath)
foreach ($marker in $requiredCommitMarkers) { if (-not $commitText.Contains($marker)) { throw "COMMIT_ARTIFACT_VALIDATION_FAIL|missing=$marker" } }
$csvRows=@(Import-Csv -LiteralPath $CsvPath)
if ($csvRows.Count -ne 966) { throw "CSV_ROW_COUNT_FAIL|expected=966|actual=$($csvRows.Count)" }
if (@($csvRows | Where-Object {$_.department_name}).Count -ne 827) { throw 'CSV_DEPARTMENT_COUNT_FAIL' }

$manifest=@('GATE6_3A_DATABASE_PACKAGE|PASS',"RUN_ID|$RunId","SOURCE_SHA256|$sourceHash",'CATALOG_ROWS|966','DETAIL_ROWS|964','COLLEGE_NON_NULL_TARGET|964','DEPARTMENT_ASSIGNED_TARGET|827','DATABASE_MUTATION|false',("CSV|{0}|sha256={1}" -f $CsvPath,(Get-FileHash $CsvPath -Algorithm SHA256).Hash.ToUpperInvariant()),("COMMIT_SQL|{0}|sha256={1}" -f $CommitPath,(Get-FileHash $CommitPath -Algorithm SHA256).Hash.ToUpperInvariant()),("ROLLBACK_SQL|{0}|sha256={1}" -f $RollbackPath,(Get-FileHash $RollbackPath -Algorithm SHA256).Hash.ToUpperInvariant()),("REFRESH_SQL|{0}|sha256={1}" -f $RefreshPath,(Get-FileHash $RefreshPath -Algorithm SHA256).Hash.ToUpperInvariant()))
$ManifestPath=Join-Path $EvidenceDir 'gate6_3a_package_manifest.txt'
Write-Utf8Lines $ManifestPath $manifest

Write-Output 'ARTIFACT_STATIC_VALIDATION|PASS'
Write-Output ("CSV_PATH|{0}" -f $CsvPath)
Write-Output ("COMMIT_SQL_PATH|{0}" -f $CommitPath)
Write-Output ("ROLLBACK_SQL_PATH|{0}" -f $RollbackPath)
Write-Output ("REFRESH_SQL_PATH|{0}" -f $RefreshPath)
Write-Output ("MANIFEST_PATH|{0}" -f $ManifestPath)
Write-Output 'DATABASE_MUTATION|false'
Write-Output 'APPLICATION_MUTATION|false'
Write-Output 'GATE6_3A_PACKAGE_GENERATION|PASS'
Write-Output 'GATE6_3A_PACKAGE_GENERATION_END'
