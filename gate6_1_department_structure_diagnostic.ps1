$ErrorActionPreference="Stop"
Set-Location "C:\Directus\relational-repository"
$excel=$null
$workbook=$null
function Fail([string]$m){throw $m}
function Clean([object]$v){return(([regex]::Replace(([string]$v).Trim(),"\s+"," ")).Trim())}
function HKey([object]$v){return((Clean $v).ToLowerInvariant()-replace"[^a-z0-9]","")}
function Safe([object]$v){return((Clean $v)-replace"[\|\[\],:]","_")}
try{
$sources=@(Get-ChildItem -LiteralPath "imports_hold" -File -ErrorAction Stop|Where-Object{$_.BaseName-like"ER_SR_1CAT_UNIV_MASTER_DETAIL*"-and$_.Extension.ToLowerInvariant()-in@(".xls",".xlsx",".xlsm")-and$_.Name-notlike"~$*"})
if($sources.Count-ne1){Fail "SOURCE_COUNT|expected=1|actual=$($sources.Count)"}
$source=$sources[0]
$hashBefore=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
$bytesBefore=[int64]$source.Length
$writeBefore=$source.LastWriteTimeUtc.ToString("o")
try{$excel=New-Object -ComObject Excel.Application}catch{Fail "EXCEL_COM_UNAVAILABLE"}
$excel.Visible=$false
$excel.DisplayAlerts=$false
$excel.AskToUpdateLinks=$false
$workbook=$excel.Workbooks.Open($source.FullName,0,$true)
if($workbook.ReadOnly-ne$true){Fail "WORKBOOK_NOT_READ_ONLY"}
$sheetCount=[int]$workbook.Worksheets.Count
$sheetResults=@()
$signatureRows=@()
for($si=1;$si-le$sheetCount;$si++){
$ws=$null
$used=$null
$range=$null
try{
$ws=$workbook.Worksheets.Item($si)
$used=$ws.UsedRange
$usedRows=[int]$used.Rows.Count
$usedCols=[int]$used.Columns.Count
$maxRows=[Math]::Min(50,$usedRows)
$maxCols=[Math]::Min(250,$usedCols)
$candidates=@()
for($row=1;$row-le$maxRows;$row++){
$range=$ws.Range($ws.Cells.Item($row,1),$ws.Cells.Item($row,$maxCols))
$values=$range.Value2
$hasId=$false
$hasOrg=$false
$hasDept=$false
$hasEff=$false
for($col=1;$col-le$maxCols;$col++){
$cell=if($values-is[Array]){$values.GetValue(1,$col)}elseif($col-eq1){$values}else{$null}
$key=HKey $cell
if([string]::IsNullOrWhiteSpace($key)){continue}
if($key.Contains("univcourseid")-or$key.Contains("universitycourseid")){$hasId=$true}
if($key.Contains("wwacadorg")-or$key.Contains("worldwideacadorg")){$hasOrg=$true}
if($key.Contains("wwdepartmentname")-or$key.Contains("worldwidedepartmentname")){$hasDept=$true}
if($key-eq"effdate"-or$key.Contains("effectivedate")){$hasEff=$true}
}
if($hasId-or$hasOrg-or$hasDept-or$hasEff){
$candidate=[pscustomobject]@{row=$row;id=$hasId;org=$hasOrg;department=$hasDept;effective_date=$hasEff}
$candidates+=$candidate
if($hasId-and$hasOrg-and$hasDept){
$signatureRows+=[pscustomobject]@{sheet=(Clean $ws.Name);row=$row;effective_date=$hasEff}
}
}
if($null-ne$range){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($range);$range=$null}
}
$sheetResults+=[pscustomobject]@{sheet=(Clean $ws.Name);used_rows=$usedRows;used_columns=$usedCols;rows_scanned=$maxRows;columns_scanned=$maxCols;candidate_rows=$candidates}
}finally{
if($null-ne$range){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($range)}
if($null-ne$used){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($used)}
if($null-ne$ws){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws)}
}
}
$format=[int]$workbook.FileFormat
$workbook.Close($false)
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)
$workbook=$null
$excel.Quit()
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
$excel=$null
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
$source.Refresh()
$hashAfter=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
$bytesAfter=[int64]$source.Length
$writeAfter=$source.LastWriteTimeUtc.ToString("o")
if($hashAfter-ne$hashBefore-or$bytesAfter-ne$bytesBefore-or$writeAfter-ne$writeBefore){Fail "SOURCE_CHANGED_DURING_INSPECTION"}
$sheetParts=@()
foreach($sheet in $sheetResults){
$candidateParts=@()
foreach($candidate in @($sheet.candidate_rows)){
$candidateParts+="r$($candidate.row)-id=$($candidate.id.ToString().ToLowerInvariant())-org=$($candidate.org.ToString().ToLowerInvariant())-dept=$($candidate.department.ToString().ToLowerInvariant())-eff=$($candidate.effective_date.ToString().ToLowerInvariant())"
}
$candidateText=if($candidateParts.Count-eq0){"none"}else{($candidateParts-join";")}
$sheetParts+="$(Safe $sheet.sheet)[rows=$($sheet.used_rows),cols=$($sheet.used_columns),scanned=$($sheet.rows_scanned)x$($sheet.columns_scanned),candidates=$candidateText]"
}
$correctReport=($signatureRows.Count-gt0)
$signatureText=if($signatureRows.Count-eq0){"none"}else{(@($signatureRows|ForEach-Object{"$(Safe $_.sheet)-row$($_.row)-eff=$($_.effective_date.ToString().ToLowerInvariant())"})-join";")}
Write-Output "PASS|GATE6_1_DEPARTMENT_WORKBOOK_STRUCTURE|file=$($source.Name)|bytes=$bytesBefore|file_format=$format|worksheets=$sheetCount|sheet_structure=$($sheetParts-join'~')|ownership_signature_rows=$($signatureRows.Count)|signatures=$signatureText|correct_report_structure=$($correctReport.ToString().ToLowerInvariant())|source_sha256=$hashBefore|source_modified=false|task6_1_3_complete=false|department_filter_enabled=false|runtime_mutated=false"
}catch{
Write-Output "FAIL|GATE6_1_DEPARTMENT_WORKBOOK_STRUCTURE|source_modified=false|task6_1_3_complete=false|department_filter_enabled=false|runtime_mutated=false|reason=$($_.Exception.Message)"
}finally{
if($null-ne$workbook){try{$workbook.Close($false)}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)}catch{}}
if($null-ne$excel){try{$excel.Quit()}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)}catch{}}
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
}
