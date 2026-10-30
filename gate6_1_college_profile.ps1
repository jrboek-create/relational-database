$ErrorActionPreference='Stop'
Set-Location 'C:\Directus\relational-repository'
$stamp=(Get-Date).ToString('yyyyMMdd_HHmmss')
$dir="evidence\gate6\gate6_1\college_profile_$stamp"
$utf8=New-Object System.Text.UTF8Encoding($false)
$created=$false
function Fail([string]$m){throw $m}
function WriteJson([string]$p,$o){[IO.File]::WriteAllText((Join-Path (Get-Location) $p),($o|ConvertTo-Json -Depth 12),$utf8)}
try{
$baselineDir='evidence\gate6\gate6_1\prechange_baseline_20261009_132212'
$baselineRecord=Join-Path $baselineDir 'gate6-1-prechange-baseline.json'
$baselineSums=Join-Path $baselineDir 'SHA256SUMS.txt'
$contract='middleware\contracts\api-courses-v1.json'
foreach($x in @($baselineRecord,$baselineSums,$contract)){if(-not(Test-Path -LiteralPath $x)){Fail "REQUIRED_ARTIFACT_MISSING|$x"}}
$expectedBaselineHash='EDBA5EB8EEC90F0DF8ADACBA0C47AC43F9651804AFB7A30147DE111DB6ACBC98'
if((Get-FileHash -LiteralPath $baselineRecord -Algorithm SHA256).Hash-ne$expectedBaselineHash){Fail 'FROZEN_BASELINE_HASH_MISMATCH'}
$candidates=@(Get-ChildItem -Path . -Recurse -File -Filter 'catalog-WW-2026-09-23.csv' -ErrorAction Stop|Where-Object{$_.FullName-notmatch '\\evidence\\|\\node_modules\\|\\\.git\\'})
if($candidates.Count-ne 1){Fail "PRIMARY_SOURCE_COUNT|expected=1|actual=$($candidates.Count)"}
$source=$candidates[0]
$data=@(Import-Csv -LiteralPath $source.FullName)
if($data.Count-eq 0){Fail 'PRIMARY_SOURCE_EMPTY'}
$headers=@($data[0].PSObject.Properties.Name)
function FindHeader([string[]]$names){foreach($n in $names){$h=@($headers|Where-Object{$_.Trim()-ieq$n}|Select-Object -First 1);if($h.Count-eq 1){return [string]$h[0]}};return $null}
$uidHeader=FindHeader @('Univ Course ID','University Course ID','university_course_id')
$codeHeader=FindHeader @('Course Code','course_code')
$titleHeader=FindHeader @('Title','Course Title','course_title')
$collegeHeader=FindHeader @('College','college')
if([string]::IsNullOrWhiteSpace($uidHeader)-or[string]::IsNullOrWhiteSpace($codeHeader)-or[string]::IsNullOrWhiteSpace($titleHeader)-or[string]::IsNullOrWhiteSpace($collegeHeader)){Fail 'REQUIRED_SOURCE_HEADERS_MISSING'}
$records=@()
foreach($r in $data){$uid=([string]$r.$uidHeader).Trim();$code=([string]$r.$codeHeader).Trim();$college=([string]$r.$collegeHeader).Trim();$records += [pscustomobject]@{uid=$uid;code=$code;college=$college}}
$page=1
$catalog=@()
do{
$api=Invoke-RestMethod -Uri "http://127.0.0.1:3001/api/courses?page=$page&limit=100&sort=course_id" -TimeoutSec 15
if($api.ok-ne$true){Fail "BASELINE_API_NOT_OK|page=$page"}
$batch=@($api.data)
foreach($r in $batch){$catalog += $r}
$page++
if($page-gt 20){Fail 'BASELINE_API_PAGE_GUARD'}
}while($batch.Count-gt 0)
if($catalog.Count-ne 966){Fail "BASELINE_CATALOG_TOTAL|expected=966|actual=$($catalog.Count)"}
$courseIds=@($catalog|ForEach-Object{([string]$_.course_id).Trim()})
$baselineIds=@($catalog|ForEach-Object{([string]$_.university_course_id).Trim()})
if(@($courseIds|Where-Object{[string]::IsNullOrWhiteSpace($_)}).Count-ne 0){Fail 'BASELINE_COURSE_ID_BLANK'}
if(@($courseIds|Sort-Object -Unique).Count-ne 966){Fail 'BASELINE_COURSE_ID_NOT_UNIQUE'}
if(@($baselineIds|Where-Object{[string]::IsNullOrWhiteSpace($_)}).Count-ne 0){Fail 'BASELINE_UNIVERSITY_COURSE_ID_BLANK'}
if(@($baselineIds|Sort-Object -Unique).Count-ne 966){Fail 'BASELINE_UNIVERSITY_COURSE_ID_NOT_UNIQUE'}
$groups=@{}
foreach($r in $records){if(-not[string]::IsNullOrWhiteSpace($r.uid)){if(-not$groups.ContainsKey($r.uid)){$groups[$r.uid]=@()};$groups[$r.uid] += $r}}
$mapped=0;$unmapped=0;$duplicate=0;$conflicting=0
foreach($id in $baselineIds){
if(-not$groups.ContainsKey($id)){$unmapped++;continue}
$g=@($groups[$id])
$colleges=@($g|ForEach-Object{$_.college}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
if($colleges.Count-eq 0){$unmapped++}elseif($colleges.Count-gt 1){$conflicting++}elseif($g.Count-gt 1){$duplicate++}else{$mapped++}
}
$sourceIds=@($records|ForEach-Object{$_.uid}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
$baselineSet=@{}
foreach($id in $baselineIds){$baselineSet[$id]=$true}
$sourceOnly=@($sourceIds|Where-Object{-not$baselineSet.ContainsKey($_)}).Count
$duplicateSourceIds=0;$conflictingSourceIds=0
foreach($k in $groups.Keys){$g=@($groups[$k]);if($g.Count-gt 1){$duplicateSourceIds++};$c=@($g|ForEach-Object{$_.college}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique);if($c.Count-gt 1){$conflictingSourceIds++}}
$blankCollegeRows=@($records|Where-Object{[string]::IsNullOrWhiteSpace($_.college)}).Count
$blankIdRows=@($records|Where-Object{[string]::IsNullOrWhiteSpace($_.uid)}).Count
$distinctCodes=@($records|ForEach-Object{$_.code}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique).Count
$rawCollegeGroups=@($records|Where-Object{-not[string]::IsNullOrWhiteSpace($_.college)}|Group-Object college|Sort-Object Name)
$inventory=@()
foreach($cg in $rawCollegeGroups){$raw=[string]$cg.Name;$norm=([regex]::Replace($raw.Trim(),'\s+',' ')).ToUpperInvariant();$inventory+=[pscustomobject]@{raw_source_value=$raw;normalized_key=$norm;source_row_count=[int]$cg.Count}}
$crosswalk=@()
foreach($ng in @($inventory|Group-Object normalized_key|Sort-Object Name)){$raws=@($ng.Group|ForEach-Object{$_.raw_source_value}|Sort-Object -Unique);$n=($ng.Group|Measure-Object source_row_count -Sum).Sum;$crosswalk+=[pscustomobject]@{canonical_key=[string]$ng.Name;raw_source_values=$raws;source_row_count=[int]$n;proposed_display_label=$(if($raws.Count-eq 1){$raws[0]}else{$null});status=$(if($raws.Count-eq 1){'deterministic'}else{'requires_review'})}}
$normalizationReview=@($crosswalk|Where-Object{$_.status-eq'requires_review'}).Count
$deterministic=($mapped-eq 966-and$unmapped-eq 0-and$duplicate-eq 0-and$conflicting-eq 0)
if(-not$deterministic){Fail "COLLEGE_RECONCILIATION_NOT_DETERMINISTIC|mapped=$mapped|unmapped=$unmapped|duplicate=$duplicate|conflicting=$conflicting|source_only=$sourceOnly"}
$sourceRelative=$source.FullName.Substring((Get-Location).Path.Length+1)
$profile=[ordered]@{source_file=$sourceRelative;source_sha256=(Get-FileHash $source.FullName -Algorithm SHA256).Hash;profiled_utc=(Get-Date).ToUniversalTime().ToString('o');source_rows=$records.Count;distinct_university_course_ids=$sourceIds.Count;distinct_course_codes=$distinctCodes;distinct_raw_college_values=$rawCollegeGroups.Count;blank_college_rows=$blankCollegeRows;blank_university_course_id_rows=$blankIdRows;duplicate_source_identifiers=$duplicateSourceIds;conflicting_source_identifiers=$conflictingSourceIds;normalization_groups_requiring_review=$normalizationReview}
$recon=[ordered]@{frozen_baseline_path=$baselineRecord;frozen_baseline_sha256=$expectedBaselineHash;baseline_courses=966;baseline_distinct_course_id=966;baseline_distinct_university_course_id=966;join_key='university_course_id = Univ Course ID';classification_rule=[ordered]@{mapped='one source row and one nonblank College';unmapped='no matching source row or no nonblank College';duplicate='multiple source rows with one nonblank College';conflicting='more than one distinct nonblank College'};mapped=$mapped;unmapped=$unmapped;duplicate=$duplicate;conflicting=$conflicting;source_only_distinct_ids=$sourceOnly;deterministic_reconciliation=$true}
New-Item -ItemType Directory -Path $dir -Force|Out-Null
$created=$true
$pp=Join-Path $dir 'college-profile.json'
$rp=Join-Path $dir 'college-reconciliation.json'
$cp=Join-Path $dir 'college-crosswalk-proposal.json'
$ap=Join-Path $dir 'artifact-manifest.json'
$vp=Join-Path $dir 'verification.json'
$sp=Join-Path $dir 'SHA256SUMS.txt'
WriteJson $pp $profile
WriteJson $rp $recon
WriteJson $cp ([ordered]@{generated_utc=(Get-Date).ToUniversalTime().ToString('o');normalization='trim, collapse whitespace, uppercase canonical key; raw values preserved';automatic_college_remapping=$false;items=$crosswalk})
$artifactPaths=@($source.FullName,$baselineRecord,$baselineSums,$contract,(Resolve-Path 'gate6_1_college_profile.ps1').Path)
$artifactManifest=@()
foreach($a in $artifactPaths){$i=Get-Item $a;$rel=$(if($i.FullName.StartsWith((Get-Location).Path)){$i.FullName.Substring((Get-Location).Path.Length+1)}else{$i.FullName});$artifactManifest+=[pscustomobject]@{path=$rel;bytes=[int64]$i.Length;algorithm='SHA256';sha256=(Get-FileHash $i.FullName -Algorithm SHA256).Hash}}
WriteJson $ap $artifactManifest
$verification=[ordered]@{verified_utc=(Get-Date).ToUniversalTime().ToString('o');task='6.1.2 College profile and reconciliation';read_only=$true;runtime_mutated=$false;database_modified=$false;services_recreated=$false;baseline_catalog_total=966;join_key='university_course_id';deterministic_reconciliation=$true;mapped=966;unmapped=0;duplicate=0;conflicting=0;secret_contents_included=$false;secret_hashes_included=$false;business_rows_included=$false;decision='PASS - TASK 6.1.2 COMPLETE'}
WriteJson $vp $verification
$files=@($pp,$rp,$cp,$ap,$vp)
$sums=@()
foreach($f in $files){$h=(Get-FileHash $f -Algorithm SHA256).Hash;$sums+="$h  $(Split-Path $f -Leaf)";$null=Get-Content -LiteralPath $f -Raw|ConvertFrom-Json}
[IO.File]::WriteAllLines((Join-Path (Get-Location) $sp),$sums,$utf8)
$sumHash=(Get-FileHash $sp -Algorithm SHA256).Hash
Write-Output "PASS|GATE6_1_COLLEGE_PROFILE_RECONCILED|dir=$dir|source_rows=$($records.Count)|source_distinct_ids=$($sourceIds.Count)|distinct_colleges=$($rawCollegeGroups.Count)|mapped=$mapped|unmapped=$unmapped|duplicate=$duplicate|conflicting=$conflicting|source_only=$sourceOnly|normalization_review=$normalizationReview|baseline=966|join_key=university_course_id|sha256sums=$sumHash|runtime_mutated=false|business_rows_included=false|secrets_included=false"
}catch{
if($created-and(Test-Path -LiteralPath $dir)){Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue}
Write-Output "FAIL|GATE6_1_COLLEGE_PROFILE|partial_package_removed=$created|runtime_mutated=false|reason=$($_.Exception.Message)"
}
