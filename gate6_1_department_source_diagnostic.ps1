$ErrorActionPreference="Stop"
Set-Location "C:\Directus\relational-repository"
$excel=$null
$workbook=$null
function Fail([string]$m){throw $m}
function Clean([object]$v){return(([regex]::Replace(([string]$v).Trim(),"\s+"," ")).Trim())}
function HKey([object]$v){return((Clean $v).ToLowerInvariant()-replace"[^a-z0-9]","")}
function Rel([string]$path){$root=(Get-Location).Path;if($path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){return $path.Substring($root.Length).TrimStart("\")};return $path}
try{
$extensions=@(".xlsx",".xlsm",".xls",".csv")
$namePattern="(?i)(catalog|undergrad|graduate|(^|[^a-z])grad([^a-z]|$)|1cat|univ.*master|master.*detail|course.*master)"
$files=@(Get-ChildItem -Path . -Recurse -File -ErrorAction Stop|Where-Object{$_.Extension.ToLowerInvariant()-in$extensions-and$_.Name-notlike"~$*"-and$_.FullName-notmatch"\\node_modules\\|\\\.git\\"-and$_.BaseName-match$namePattern}|Sort-Object FullName -Unique)
$results=@()
$excelFiles=@($files|Where-Object{$_.Extension.ToLowerInvariant()-in@(".xlsx",".xlsm",".xls")})
if($excelFiles.Count-gt0){
try{$excel=New-Object -ComObject Excel.Application}catch{$excel=$null}
if($null-ne$excel){$excel.Visible=$false;$excel.DisplayAlerts=$false;$excel.AskToUpdateLinks=$false}
}
foreach($file in $files){
$matchedSheets=@()
$headerSummary=@()
$ext=$file.Extension.ToLowerInvariant()
if($ext-eq".csv"){
try{
$first=Import-Csv -LiteralPath $file.FullName|Select-Object -First 1
if($null-ne$first){
$keys=@($first.PSObject.Properties.Name|ForEach-Object{HKey $_})
$hasId=("univcourseid"-in$keys-or"universitycourseid"-in$keys)
$hasOrg=("wwacadorg"-in$keys-or"worldwideacadorg"-in$keys)
$hasDept=("wwdepartmentname"-in$keys-or"worldwidedepartmentname"-in$keys)
$headerSummary+="csv:id=$hasId,org=$hasOrg,dept=$hasDept"
if($hasId-and$hasOrg-and$hasDept){$matchedSheets+="CSV"}
}
}catch{$headerSummary+="csv:inspection_error"}
}elseif($null-ne$excel){
try{
$workbook=$excel.Workbooks.Open($file.FullName,0,$true)
for($si=1;$si-le$workbook.Worksheets.Count;$si++){
$ws=$null;$used=$null;$range=$null
try{
$ws=$workbook.Worksheets.Item($si)
$used=$ws.UsedRange
$maxRows=[Math]::Min(20,[int]$used.Rows.Count)
$maxCols=[Math]::Min(100,[int]$used.Columns.Count)
$found=$false
for($hr=1;$hr-le$maxRows;$hr++){
$range=$ws.Range($ws.Cells.Item($hr,1),$ws.Cells.Item($hr,$maxCols))
$values=$range.Value2
$keys=@()
if($values-is[Array]){for($c=1;$c-le$maxCols;$c++){$keys+=HKey $values.GetValue(1,$c)}}else{$keys+=HKey $values}
$hasId=("univcourseid"-in$keys-or"universitycourseid"-in$keys)
$hasOrg=("wwacadorg"-in$keys-or"worldwideacadorg"-in$keys)
$hasDept=("wwdepartmentname"-in$keys-or"worldwidedepartmentname"-in$keys)
if($hasId-or$hasOrg-or$hasDept){$headerSummary+="$(Clean $ws.Name):id=$hasId,org=$hasOrg,dept=$hasDept,row=$hr"}
if($hasId-and$hasOrg-and$hasDept){$matchedSheets+="$(Clean $ws.Name)";$found=$true;break}
if($null-ne$range){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($range);$range=$null}
}
}finally{
if($null-ne$range){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($range)}
if($null-ne$used){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($used)}
if($null-ne$ws){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws)}
}
}
}catch{$headerSummary+="workbook:inspection_error"}finally{
if($null-ne$workbook){$workbook.Close($false);[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook);$workbook=$null}
}
}else{$headerSummary+="workbook:excel_com_unavailable"}
$family=if($file.BaseName-match"(?i)^ER_SR_1CAT_UNIV_MASTER_DETAIL"){"institutional_master_detail"}elseif($file.BaseName-match"(?i)^Undergrad"){"undergraduate_catalog"}elseif($file.BaseName-match"(?i)^(Grad|Graduate)"){"graduate_catalog"}else{"other_catalog_candidate"}
$results+=[pscustomobject]@{relative_path=(Rel $file.FullName);family=$family;complete_headers=($matchedSheets.Count-gt0);matching_sheets=@($matchedSheets);header_checks=@($headerSummary)}
}
$complete=@($results|Where-Object{$_.complete_headers})
$master=@($complete|Where-Object{$_.family-eq"institutional_master_detail"})
$undergrad=@($complete|Where-Object{$_.family-eq"undergraduate_catalog"})
$graduate=@($complete|Where-Object{$_.family-eq"graduate_catalog"})
$sourceMode="none"
$deterministic=$false
if($master.Count-eq1){$sourceMode="institutional_master_detail";$deterministic=$true}
elseif($master.Count-gt1){$sourceMode="multiple_master_detail_candidates"}
elseif($undergrad.Count-ge1-and$graduate.Count-ge1){$sourceMode="split_undergraduate_graduate_catalogs";$deterministic=$true}
elseif($complete.Count-gt0){$sourceMode="incomplete_catalog_source_set"}
$textExtensions=@(".json",".txt",".md",".sql",".ps1",".csv")
$referenceFiles=@(Get-ChildItem -Path . -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension.ToLowerInvariant()-in$textExtensions-and$_.Length-lt5242880-and$_.FullName-notmatch"\\node_modules\\|\\\.git\\"})
$referenceHits=@()
foreach($rf in $referenceFiles){
try{if(Select-String -LiteralPath $rf.FullName -Pattern "Undergrad Catalog.xlsx","Grad - Master.xlsx","Grad - Doctor.xlsx","ER_SR_1CAT_UNIV_MASTER_DETAIL" -SimpleMatch -Quiet){$referenceHits+=Rel $rf.FullName}}catch{}
}
$referenceHits=@($referenceHits|Sort-Object -Unique)
$fileText=if($results.Count-eq0){"none"}else{(@($results|ForEach-Object{"$(Clean $_.relative_path)[$($_.family)]"})-join"~")}
$matchText=if($complete.Count-eq0){"none"}else{(@($complete|ForEach-Object{"$(Clean $_.relative_path){$((@($_.matching_sheets)-join","))}"})-join"~")}
$refText=if($referenceHits.Count-eq0){"none"}else{(@($referenceHits|Select-Object -First 20)-join"~")}
Write-Output "PASS|GATE6_1_DEPARTMENT_SOURCE_DIAGNOSTIC|candidate_files=$($results.Count)|complete_header_files=$($complete.Count)|master_detail_matches=$($master.Count)|undergrad_matches=$($undergrad.Count)|graduate_matches=$($graduate.Count)|excel_com_available=$(($null-ne$excel).ToString().ToLowerInvariant())|source_mode=$sourceMode|deterministic_source_set=$($deterministic.ToString().ToLowerInvariant())|files=$fileText|complete_matches=$matchText|inventory_reference_hits=$($referenceHits.Count)|references=$refText|department_filter_enabled=false|task6_1_3_complete=false|runtime_mutated=false"
}catch{
Write-Output "FAIL|GATE6_1_DEPARTMENT_SOURCE_DIAGNOSTIC|department_filter_enabled=false|runtime_mutated=false|reason=$($_.Exception.Message)"
}finally{
if($null-ne$workbook){try{$workbook.Close($false)}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)}catch{}}
if($null-ne$excel){try{$excel.Quit()}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)}catch{}}
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
}
