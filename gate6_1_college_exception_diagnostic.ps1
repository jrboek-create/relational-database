$ErrorActionPreference="Stop"
Set-Location "C:\Directus\relational-repository"
$excel=$null
$workbook=$null
function Fail([string]$m){throw $m}
function Clean([object]$v){$s=[string]$v;$s=$s-replace"[\r\n|~]"," ";return(($s-replace"\s+"," ").Trim())}
function Norm([object]$v){return((Clean $v).ToUpperInvariant()-replace"\s+"," ")}
function Key([object]$v){return((Clean $v).ToLowerInvariant()-replace"[^a-z0-9]","")}
function Cell($v,[int]$r,[int]$c){if($v-is[Array]){return[string]$v.GetValue($r,$c)};if($r-eq1-and$c-eq1){return[string]$v};return""}
try{
$csv=@(Get-ChildItem -Path . -Recurse -File -Filter "catalog-WW-2026-09-23.csv" -ErrorAction Stop|Where-Object{$_.FullName-notmatch"\\evidence\\|\\node_modules\\|\\\.git\\"})
if($csv.Count-ne1){Fail "PRIMARY_SOURCE_COUNT|actual=$($csv.Count)"}
$rows=@(Import-Csv -LiteralPath $csv[0].FullName)
if($rows.Count-eq0){Fail "PRIMARY_SOURCE_EMPTY"}
$byId=@{}
foreach($row in $rows){
$id=Clean $row.PSObject.Properties["Univ Course ID"].Value
if(-not[string]::IsNullOrWhiteSpace($id)){
if(-not$byId.ContainsKey($id)){$byId[$id]=@()}
$byId[$id]+=$row
}
}
$catalog=@()
$page=1
$total=0
do{
$api=Invoke-RestMethod -Uri "http://127.0.0.1:3001/api/courses?page=$page&limit=100&sort=course_id" -TimeoutSec 15
if($api.ok-ne$true){Fail "BASELINE_API_NOT_OK|page=$page"}
$total=[int]$api.meta.total
$catalog+=@($api.data)
$page++
if($page-gt20){Fail "BASELINE_API_PAGE_GUARD"}
}while($catalog.Count-lt$total)
if($total-ne966-or$catalog.Count-ne966){Fail "BASELINE_TOTAL|meta=$total|rows=$($catalog.Count)"}
$exceptions=@()
foreach($course in $catalog){
$id=Clean $course.university_course_id
$exists=$byId.ContainsKey($id)
$matched=if($exists){@($byId[$id])}else{@()}
$colleges=@($matched|ForEach-Object{Clean $_.PSObject.Properties["College"].Value}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
if(-not$exists-or$colleges.Count-eq0){
$exceptions+=[pscustomobject]@{id=$id;code=(Clean $course.course_code);title=(Clean $course.course_title);exists=$exists;blank=($exists-and$colleges.Count-eq0);reason=$(if(-not$exists){"source_id_absent"}else{"primary_college_blank"})}
}
}
if($exceptions.Count-ne2){Fail "EXCEPTION_COUNT|expected=2|actual=$($exceptions.Count)"}
$names=@("ER_SR_1CAT_UNIV_MASTER_DETAIL_1512061533.xlsx","Undergrad Catalog.xlsx","Grad - Master.xlsx","Graduate Catalog.xlsx","University Catalog Toolbox 1.0.xlsm","College.xlsx")
$files=@(Get-ChildItem -Path . -Recurse -File -ErrorAction Stop|Where-Object{$_.Name-in$names-and$_.Name-notlike"~$*"-and$_.FullName-notmatch"\\evidence\\|\\node_modules\\|\\\.git\\"}|Sort-Object FullName -Unique)
$candidates=@()
if($files.Count-gt0){
try{$excel=New-Object -ComObject Excel.Application}catch{Fail "EXCEL_COM_UNAVAILABLE"}
$excel.Visible=$false
$excel.DisplayAlerts=$false
$excel.AskToUpdateLinks=$false
foreach($file in $files){
try{
$workbook=$excel.Workbooks.Open($file.FullName,0,$true)
for($si=1;$si-le$workbook.Worksheets.Count;$si++){
$ws=$null
$used=$null
try{
$ws=$workbook.Worksheets.Item($si)
$used=$ws.UsedRange
$rc=[int]$used.Rows.Count
$cc=[int]$used.Columns.Count
if($rc-lt2-or$cc-lt2){continue}
$values=$used.Value2
$header=0
$idCol=0
$codeCol=0
$subjectCol=0
$numberCol=0
$collegeCol=0
for($hr=1;$hr-le[Math]::Min(20,$rc);$hr++){
$map=@{}
for($c=1;$c-le$cc;$c++){
$k=Key (Cell $values $hr $c)
if(-not[string]::IsNullOrWhiteSpace($k)-and-not$map.ContainsKey($k)){$map[$k]=$c}
}
foreach($k in @("univcourseid","universitycourseid")){if($map.ContainsKey($k)){$idCol=[int]$map[$k];break}}
foreach($k in @("coursecode","newcourse","onmaster")){if($map.ContainsKey($k)){$codeCol=[int]$map[$k];break}}
foreach($k in @("univsubject","subject")){if($map.ContainsKey($k)){$subjectCol=[int]$map[$k];break}}
foreach($k in @("univcatalognbr","catalognumber","catalognbr")){if($map.ContainsKey($k)){$numberCol=[int]$map[$k];break}}
foreach($k in @("college","collegefororg","wwcollege")){if($map.ContainsKey($k)){$collegeCol=[int]$map[$k];break}}
if($collegeCol-gt0-and($idCol-gt0-or$codeCol-gt0-or($subjectCol-gt0-and$numberCol-gt0))){$header=$hr;break}
$idCol=0
$codeCol=0
$subjectCol=0
$numberCol=0
$collegeCol=0
}
if($header-eq0){continue}
for($r=$header+1;$r-le$rc;$r++){
$rowId=if($idCol-gt0){Clean (Cell $values $r $idCol)}else{""}
$rowCode=""
if($codeCol-gt0){$rowCode=Norm (Cell $values $r $codeCol)}elseif($subjectCol-gt0-and$numberCol-gt0){$rowCode=Norm ("$(Cell $values $r $subjectCol) $(Cell $values $r $numberCol)")}
$college=Clean (Cell $values $r $collegeCol)
if([string]::IsNullOrWhiteSpace($college)-or$college-match"^#"){continue}
foreach($e in $exceptions){
$idMatch=(-not[string]::IsNullOrWhiteSpace($rowId)-and$rowId-eq$e.id)
$codeMatch=(-not[string]::IsNullOrWhiteSpace($rowCode)-and$rowCode-eq(Norm $e.code))
if($idMatch-or$codeMatch){
$candidates+=[pscustomobject]@{code=$e.code;college=$college;file=$file.Name;method=$(if($idMatch){"university_course_id"}else{"course_code"})}
}
}
}
}finally{
if($null-ne$used){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($used)}
if($null-ne$ws){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws)}
}
}
}finally{
if($null-ne$workbook){$workbook.Close($false);[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook);$workbook=$null}
}
}
}
$parts=@()
$resolved=0
foreach($e in $exceptions){
$matches=@($candidates|Where-Object{$_.code-eq$e.code})
$all=@($matches|ForEach-Object{Clean $_.college}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
$idMatches=@($matches|Where-Object{$_.method-eq"university_course_id"}|ForEach-Object{Clean $_.college}|Sort-Object -Unique)
$deterministic=($all.Count-eq1-and$idMatches.Count-eq1)
if($deterministic){$resolved++}
$candidate=if($all.Count-eq0){"none"}else{Clean ($all-join",")}
$method=if($idMatches.Count-eq1){"university_course_id"}elseif($all.Count-gt0){"course_code_only"}else{"none"}
$sourceNames=@($matches|ForEach-Object{$_.file}|Sort-Object -Unique)
$sourceText=if($sourceNames.Count-eq0){"none"}else{Clean ($sourceNames-join",")}
$parts+="course=$(Clean $e.code)~title=$(Clean $e.title)~source_id_exists=$($e.exists.ToString().ToLowerInvariant())~college_blank=$($e.blank.ToString().ToLowerInvariant())~reason=$($e.reason)~candidate=$candidate~match=$method~sources=$sourceText~deterministic=$($deterministic.ToString().ToLowerInvariant())"
}
$full=($resolved-eq2)
Write-Output "PASS|GATE6_1_COLLEGE_EXCEPTION_DIAGNOSTIC|exceptions=2|authoritative_files_found=$($files.Count)|resolved=$resolved|fully_deterministic=$($full.ToString().ToLowerInvariant())|$($parts-join'|')|task6_1_2_accepted=false|runtime_mutated=false"
}catch{
Write-Output "FAIL|GATE6_1_COLLEGE_EXCEPTION_DIAGNOSTIC|runtime_mutated=false|reason=$($_.Exception.Message)"
}finally{
if($null-ne$workbook){try{$workbook.Close($false)}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)}catch{}}
if($null-ne$excel){try{$excel.Quit()}catch{};try{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)}catch{}}
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
}
