$ErrorActionPreference="Stop"
Set-Location "C:\Directus\relational-repository"
$stamp=(Get-Date).ToString("yyyyMMdd_HHmmss")
$dir="evidence\gate6\gate6_1\department_source_verification_$stamp"
$utf8=New-Object System.Text.UTF8Encoding($false)
$created=$false
$excel=$null
$workbook=$null
function Fail([string]$m){throw $m}
function Clean([object]$v){return(([regex]::Replace(([string]$v).Trim(),"\s+"," ")).Trim())}
function HKey([object]$v){return((Clean $v).ToLowerInvariant()-replace"[^a-z0-9]","")}
function WriteJson([string]$path,$value){[IO.File]::WriteAllText((Join-Path (Get-Location) $path),($value|ConvertTo-Json -Depth 12),$utf8)}
try{
$baseline="evidence\gate6\gate6_1\prechange_baseline_20261009_132212\gate6-1-prechange-baseline.json"
$college="evidence\gate6\gate6_1\college_profile_20261009_154253\college-reconciliation-exceptions.json"
foreach($required in @($baseline,$college)){if(-not(Test-Path -LiteralPath $required)){Fail "REQUIRED_EVIDENCE_MISSING|$required"}}
if((Get-FileHash -LiteralPath $baseline -Algorithm SHA256).Hash-ne"EDBA5EB8EEC90F0DF8ADACBA0C47AC43F9651804AFB7A30147DE111DB6ACBC98"){Fail "BASELINE_HASH_MISMATCH"}
if((Get-FileHash -LiteralPath $college -Algorithm SHA256).Hash-ne"0B185B266DC29E546311411B1AC2608B309C3DF5991B5CF05673B0BD25C1B9F7"){Fail "COLLEGE_EVIDENCE_HASH_MISMATCH"}
$sources=@(Get-ChildItem -LiteralPath "imports_hold" -File -ErrorAction Stop|Where-Object{$_.BaseName-like"ER_SR_1CAT_UNIV_MASTER_DETAIL*"-and$_.Extension.ToLowerInvariant()-in@(".xls",".xlsx",".xlsm")-and$_.Name-notlike"~$*"})
if($sources.Count-ne1){Fail "DEPARTMENT_SOURCE_COUNT|expected=1|actual=$($sources.Count)"}
$source=$sources[0]
$sourceHashBefore=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
$sourceBytesBefore=[int64]$source.Length
$sourceWriteBefore=$source.LastWriteTimeUtc.ToString("o")
try{$excel=New-Object -ComObject Excel.Application}catch{Fail "EXCEL_COM_UNAVAILABLE"}
$excel.Visible=$false
$excel.DisplayAlerts=$false
$excel.AskToUpdateLinks=$false
$workbook=$excel.Workbooks.Open($source.FullName,0,$true)
if($workbook.ReadOnly-ne$true){Fail "WORKBOOK_NOT_OPENED_READ_ONLY"}
$worksheetCount=[int]$workbook.Worksheets.Count
$matches=@()
for($si=1;$si-le$worksheetCount;$si++){
$ws=$null
$used=$null
$range=$null
try{
$ws=$workbook.Worksheets.Item($si)
$used=$ws.UsedRange
$usedRows=[int]$used.Rows.Count
$usedCols=[int]$used.Columns.Count
$maxRows=[Math]::Min(25,$usedRows)
$maxCols=[Math]::Min(150,$usedCols)
for($row=1;$row-le$maxRows;$row++){
$range=$ws.Range($ws.Cells.Item($row,1),$ws.Cells.Item($row,$maxCols))
$values=$range.Value2
$keys=@()
if($values-is[Array]){
for($col=1;$col-le$maxCols;$col++){$keys+=HKey $values.GetValue(1,$col)}
}else{
$keys+=HKey $values
}
$hasId=("univcourseid"-in$keys-or"universitycourseid"-in$keys)
$hasOrg=("wwacadorg"-in$keys-or"worldwideacadorg"-in$keys)
$hasDept=("wwdepartmentname"-in$keys-or"worldwidedepartmentname"-in$keys)
$hasEff=("effdate"-in$keys-or"effectivedate"-in$keys)
if($hasId-and$hasOrg-and$hasDept){
$matches+=[pscustomobject]@{sheet=(Clean $ws.Name);header_row=$row;used_rows=$usedRows;used_columns=$usedCols;effective_date_present=$hasEff}
break
}
if($null-ne$range){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($range);$range=$null}
}
}finally{
if($null-ne$range){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($range)}
if($null-ne$used){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($used)}
if($null-ne$ws){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws)}
}
}
if($matches.Count-eq0){Fail "REQUIRED_OWNERSHIP_HEADERS_NOT_FOUND"}
$workbook.Close($false)
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)
$workbook=$null
$excel.Quit()
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
$excel=$null
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
$source.Refresh()
$sourceHashAfter=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
$sourceBytesAfter=[int64]$source.Length
$sourceWriteAfter=$source.LastWriteTimeUtc.ToString("o")
if($sourceHashAfter-ne$sourceHashBefore-or$sourceBytesAfter-ne$sourceBytesBefore-or$sourceWriteAfter-ne$sourceWriteBefore){Fail "SOURCE_CHANGED_DURING_VERIFICATION"}
$effectiveDatePresent=(@($matches|Where-Object{$_.effective_date_present}).Count-gt0)
New-Item -ItemType Directory -Path $dir -Force|Out-Null
$created=$true
$recordPath=Join-Path $dir "department-source-verification.json"
$manifestPath=Join-Path $dir "artifact-manifest.json"
$verificationPath=Join-Path $dir "verification.json"
$sumsPath=Join-Path $dir "SHA256SUMS.txt"
$record=[ordered]@{
task="6.1.3 Department source verification"
status="PASS - AUTHORITATIVE SOURCE VERIFIED"
verified_utc=(Get-Date).ToUniversalTime().ToString("o")
source_family="ER_SR_1CAT_UNIV_MASTER_DETAIL"
source_file=("imports_hold\"+$source.Name)
source_sha256=$sourceHashBefore
source_bytes=$sourceBytesBefore
opened_read_only=$true
source_content_modified=$false
worksheet_count=$worksheetCount
matching_header_locations=$matches
required_fields=[ordered]@{univ_course_id=$true;ww_acad_org=$true;ww_department_name=$true;effective_date_present=$effectiveDatePresent}
department_reconciliation_executed=$false
department_filter_enabled=$false
runtime_mutated=$false
}
WriteJson $recordPath $record
$artifactPaths=@($source.FullName,(Resolve-Path $p).Path,(Resolve-Path $baseline).Path,(Resolve-Path $college).Path)
$manifest=@()
foreach($artifact in $artifactPaths){
$item=Get-Item -LiteralPath $artifact
$relative=if($item.FullName.StartsWith((Get-Location).Path,[StringComparison]::OrdinalIgnoreCase)){$item.FullName.Substring((Get-Location).Path.Length+1)}else{$item.FullName}
$manifest+=[pscustomobject]@{path=$relative;bytes=[int64]$item.Length;algorithm="SHA256";sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}
}
WriteJson $manifestPath $manifest
$verification=[ordered]@{
verified_utc=(Get-Date).ToUniversalTime().ToString("o")
source_exists=$true
filename_family_verified=$true
sha256_recorded=$true
workbook_opened_read_only=$true
required_headers_verified=$true
source_unchanged_after_verification=$true
effective_date_present=$effectiveDatePresent
task6_1_3_complete=$false
department_reconciliation_executed=$false
department_filter_enabled=$false
runtime_mutated=$false
secret_contents_included=$false
business_rows_included=$false
decision="PASS - SOURCE READY FOR READ-ONLY DEPARTMENT RECONCILIATION"
}
WriteJson $verificationPath $verification
$outputs=@($recordPath,$manifestPath,$verificationPath)
$sums=@()
foreach($output in $outputs){
$null=Get-Content -LiteralPath $output -Raw|ConvertFrom-Json
$hash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
$sums+="$hash  $(Split-Path $output -Leaf)"
}
[IO.File]::WriteAllLines((Join-Path (Get-Location) $sumsPath),$sums,$utf8)
$sumsHash=(Get-FileHash -LiteralPath $sumsPath -Algorithm SHA256).Hash
Write-Output "PASS|GATE6_1_DEPARTMENT_SOURCE_VERIFIED|dir=$dir|file=$($source.Name)|bytes=$sourceBytesBefore|worksheets=$worksheetCount|matching_header_sheets=$($matches.Count)|headers=univ_course_id,ww_acad_org,ww_department_name|effective_date_present=$($effectiveDatePresent.ToString().ToLowerInvariant())|source_sha256=$sourceHashBefore|sha256sums=$sumsHash|source_modified=false|reconciliation_executed=false|task6_1_3_complete=false|department_filter_enabled=false|runtime_mutated=false"
}catch{
if($created-and(Test-Path -LiteralPath $dir)){Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue}
Write-Output "FAIL|GATE6_1_DEPARTMENT_SOURCE_VERIFICATION|partial_package_removed=$created|source_modified=false|reconciliation_executed=false|department_filter_enabled=false|runtime_mutated=false|reason=$($_.Exception.Message)"
}finally{
if($null-ne$workbook){try{$workbook.Close($false)}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)}catch{}}
if($null-ne$excel){try{$excel.Quit()}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)}catch{}}
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
}
