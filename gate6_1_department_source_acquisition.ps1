$ErrorActionPreference="Stop"
Set-Location "C:\Directus\relational-repository"
$stamp=(Get-Date).ToString("yyyyMMdd_HHmmss")
$evidenceDir="evidence\gate6\gate6_1\department_source_verification_$stamp"
$importsHold=(Resolve-Path "imports_hold").Path
$utf8=New-Object System.Text.UTF8Encoding($false)
$evidenceCreated=$false
$sourceCopied=$false
$copiedPath=$null
$excel=$null
$workbook=$null
function Fail([string]$m){throw $m}
function Clean([object]$v){return(([regex]::Replace(([string]$v).Trim(),"\s+"," ")).Trim())}
function HKey([object]$v){return((Clean $v).ToLowerInvariant()-replace"[^a-z0-9]","")}
function WriteJson([string]$path,$value){[IO.File]::WriteAllText((Join-Path (Get-Location) $path),($value|ConvertTo-Json -Depth 10),$utf8)}
try{
$expectedName="ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls"
$roots=@($importsHold)
$possibleRoots=@(
(Join-Path $env:USERPROFILE "Downloads"),
(Join-Path $env:USERPROFILE "Desktop"),
$env:OneDrive,
$env:OneDriveCommercial,
(Join-Path $env:USERPROFILE "OneDrive - Embry-Riddle Aeronautical University")
)
foreach($root in $possibleRoots){
if(-not[string]::IsNullOrWhiteSpace($root)-and(Test-Path -LiteralPath $root)){
$resolved=(Resolve-Path $root).Path
if($resolved-notin$roots){$roots+=$resolved}
}
}
$candidates=@()
foreach($root in $roots){
$candidates+=@(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Name-ieq$expectedName})
}
$candidates=@($candidates|Sort-Object FullName -Unique)
if($candidates.Count-eq0){
Fail "SOURCE_NOT_FOUND|download_unchanged=$expectedName|place_in=imports_hold"
}
$candidateInfo=@()
foreach($candidate in $candidates){
$candidateInfo+=[pscustomobject]@{file=$candidate;hash=(Get-FileHash -LiteralPath $candidate.FullName -Algorithm SHA256).Hash;bytes=[int64]$candidate.Length}
}
$hashes=@($candidateInfo|ForEach-Object{$_.hash}|Sort-Object -Unique)
if($hashes.Count-ne1){Fail "SOURCE_COPIES_DIFFER|copies=$($candidates.Count)|hashes=$($hashes.Count)"}
$controlled=@($candidateInfo|Where-Object{$_.file.DirectoryName-ieq$importsHold})
$selected=if($controlled.Count-gt0){$controlled[0]}else{$candidateInfo[0]}
$destination=Join-Path $importsHold $expectedName
if($selected.file.FullName-ine$destination){
if(Test-Path -LiteralPath $destination){
$existingHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
if($existingHash-ne$selected.hash){Fail "CONTROLLED_SOURCE_HASH_CONFLICT"}
}else{
Copy-Item -LiteralPath $selected.file.FullName -Destination $destination
$sourceCopied=$true
$copiedPath=$destination
}
}
if(-not(Test-Path -LiteralPath $destination)){Fail "CONTROLLED_SOURCE_COPY_MISSING"}
$destinationHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
$destinationBytes=[int64](Get-Item -LiteralPath $destination).Length
if($destinationHash-ne$selected.hash-or$destinationBytes-ne$selected.bytes){Fail "SOURCE_COPY_VERIFICATION_FAILED"}
try{$excel=New-Object -ComObject Excel.Application}catch{Fail "EXCEL_COM_UNAVAILABLE"}
$excel.Visible=$false
$excel.DisplayAlerts=$false
$excel.AskToUpdateLinks=$false
$workbook=$excel.Workbooks.Open($destination,0,$true)
$headerFound=$false
$headerSheet=""
$headerRow=0
$usedRows=0
$effectiveDatePresent=$false
for($si=1;$si-le$workbook.Worksheets.Count-and-not$headerFound;$si++){
$ws=$null
$used=$null
$range=$null
try{
$ws=$workbook.Worksheets.Item($si)
$used=$ws.UsedRange
$usedRows=[int]$used.Rows.Count
$maxRows=[Math]::Min(25,[int]$used.Rows.Count)
$maxCols=[Math]::Min(120,[int]$used.Columns.Count)
for($r=1;$r-le$maxRows-and-not$headerFound;$r++){
$range=$ws.Range($ws.Cells.Item($r,1),$ws.Cells.Item($r,$maxCols))
$values=$range.Value2
$keys=@()
if($values-is[Array]){
for($c=1;$c-le$maxCols;$c++){$keys+=HKey $values.GetValue(1,$c)}
}else{
$keys+=HKey $values
}
$hasId=("univcourseid"-in$keys-or"universitycourseid"-in$keys)
$hasOrg=("wwacadorg"-in$keys-or"worldwideacadorg"-in$keys)
$hasDepartment=("wwdepartmentname"-in$keys-or"worldwidedepartmentname"-in$keys)
$hasEff=("effdate"-in$keys-or"effectivedate"-in$keys)
if($hasId-and$hasOrg-and$hasDepartment){
$headerFound=$true
$headerSheet=Clean $ws.Name
$headerRow=$r
$effectiveDatePresent=$hasEff
}
if($null-ne$range){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($range);$range=$null}
}
}finally{
if($null-ne$range){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($range)}
if($null-ne$used){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($used)}
if($null-ne$ws){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws)}
}
}
if(-not$headerFound){Fail "REQUIRED_DEPARTMENT_HEADERS_NOT_FOUND"}
$workbook.Close($false)
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)
$workbook=$null
$excel.Quit()
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
$excel=$null
New-Item -ItemType Directory -Path $evidenceDir -Force|Out-Null
$evidenceCreated=$true
$recordPath=Join-Path $evidenceDir "department-source-verification.json"
$manifestPath=Join-Path $evidenceDir "artifact-manifest.json"
$verificationPath=Join-Path $evidenceDir "verification.json"
$sumsPath=Join-Path $evidenceDir "SHA256SUMS.txt"
$record=[ordered]@{
task="6.1.3 Department source acquisition and verification"
status="PASS - AUTHORITATIVE SOURCE VERIFIED"
verified_utc=(Get-Date).ToUniversalTime().ToString("o")
enterprise_source="ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls"
query_name="ER_SR_1CAT_UNIV_MASTER_DETAIL"
controlled_source_path="imports_hold\ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls"
source_sha256=$destinationHash
source_bytes=$destinationBytes
source_copied_to_controlled_area=$sourceCopied
source_content_modified=$false
required_headers=[ordered]@{univ_course_id=$true;ww_acad_org=$true;ww_department_name=$true;effective_date_present=$effectiveDatePresent}
header_sheet=$headerSheet
header_row=$headerRow
worksheet_used_rows=$usedRows
department_reconciliation_executed=$false
department_filter_enabled=$false
runtime_mutated=$false
}
WriteJson $recordPath $record
$artifacts=@(
[pscustomobject]@{path="imports_hold\ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls";bytes=$destinationBytes;algorithm="SHA256";sha256=$destinationHash},
[pscustomobject]@{path="gate6_1_department_source_acquisition.ps1";bytes=[int64](Get-Item $p).Length;algorithm="SHA256";sha256=(Get-FileHash $p -Algorithm SHA256).Hash}
)
WriteJson $manifestPath $artifacts
$verification=[ordered]@{
verified_utc=(Get-Date).ToUniversalTime().ToString("o")
filename_verified=$true
copy_hash_verified=$true
copy_size_verified=$true
required_headers_verified=$true
source_content_modified=$false
business_rows_included_in_evidence=$false
secret_contents_included=$false
task6_1_3_complete=$false
decision="PASS - SOURCE READY FOR DEPARTMENT RECONCILIATION"
}
WriteJson $verificationPath $verification
$outputs=@($recordPath,$manifestPath,$verificationPath)
$sums=@()
foreach($file in $outputs){
$null=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json
$hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
$sums+="$hash  $(Split-Path $file -Leaf)"
}
[IO.File]::WriteAllLines((Join-Path (Get-Location) $sumsPath),$sums,$utf8)
$sumsHash=(Get-FileHash -LiteralPath $sumsPath -Algorithm SHA256).Hash
Write-Output "PASS|GATE6_1_DEPARTMENT_SOURCE_VERIFIED|dir=$evidenceDir|file=$expectedName|copies_found=$($candidates.Count)|copied_to_imports_hold=$($sourceCopied.ToString().ToLowerInvariant())|headers=univ_course_id,ww_acad_org,ww_department_name|effective_date_present=$($effectiveDatePresent.ToString().ToLowerInvariant())|header_sheet=$headerSheet|header_row=$headerRow|source_sha256=$destinationHash|sha256sums=$sumsHash|task6_1_3_complete=false|department_filter_enabled=false|runtime_mutated=false"
}catch{
if($evidenceCreated-and(Test-Path -LiteralPath $evidenceDir)){Remove-Item -LiteralPath $evidenceDir -Recurse -Force -ErrorAction SilentlyContinue}
if($sourceCopied-and$null-ne$copiedPath-and(Test-Path -LiteralPath $copiedPath)){Remove-Item -LiteralPath $copiedPath -Force -ErrorAction SilentlyContinue}
Write-Output "FAIL|GATE6_1_DEPARTMENT_SOURCE_VERIFICATION|partial_evidence_removed=$evidenceCreated|copied_source_removed=$sourceCopied|department_filter_enabled=false|runtime_mutated=false|reason=$($_.Exception.Message)"
}finally{
if($null-ne$workbook){try{$workbook.Close($false)}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)}catch{}}
if($null-ne$excel){try{$excel.Quit()}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)}catch{}}
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
}
