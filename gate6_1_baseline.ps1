$ErrorActionPreference='Stop'
Set-Location 'C:\Directus\relational-repository'
$stamp=(Get-Date).ToString('yyyyMMdd_HHmmss')
$dir="evidence\gate6\gate6_1\prechange_baseline_$stamp"
$utf8=New-Object System.Text.UTF8Encoding($false)
$created=$false
$token=$null
function Stop-Fail([string]$m){throw $m}
function Get-Inspect([string]$s){$id=(@(docker compose ps -q $s 2>$null)-join '').Trim();if([string]::IsNullOrWhiteSpace($id)){Stop-Fail "SERVICE_NOT_FOUND|$s"};return @((docker inspect $id 2>$null|ConvertFrom-Json))[0]}
function Get-Status([string]$u,[string]$m='GET',$h=$null){try{$q=@{Uri=$u;Method=$m;UseBasicParsing=$true;TimeoutSec=10;ErrorAction='Stop'};if($h){$q.Headers=$h};if($m-eq'POST'){$q.Body='{}';$q.ContentType='application/json'};$r=Invoke-WebRequest @q;return [int]$r.StatusCode}catch{if($_.Exception.Response){return [int]$_.Exception.Response.StatusCode.value__};throw}}
function Write-Json([string]$p,$o){$j=$o|ConvertTo-Json -Depth 12;[IO.File]::WriteAllText((Join-Path (Get-Location) $p),$j,$utf8)}
try{
$artifacts=@(
'gate6_1_baseline.ps1',
'compose.yaml',
'middleware\contracts\api-courses-v1.json',
'middleware\src\server.js',
'middleware\Dockerfile',
'middleware\package.json',
'middleware\package-lock.json',
'ui\Dockerfile',
'ui\default.conf',
'ui\index.html',
'ui\styles.css',
'ui\app.js',
'evidence\gate5\closure_20261006_075904\gate5-closure.json',
'evidence\gate6\ui_start_checkpoint_20261009_111228\gate6-ui-start-checkpoint.json',
'evidence\gate6\ui_start_checkpoint_20261009_111228\source-artifact-manifest.json',
'evidence\gate6\ui_start_checkpoint_20261009_111228\SHA256SUMS.txt',
'evidence\gate6\ui_scaffold_20261009_112144\ui-scaffold-manifest.json'
)
foreach($a in $artifacts){if(-not(Test-Path -LiteralPath $a)){Stop-Fail "REQUIRED_ARTIFACT_MISSING|$a"}}
if((Get-FileHash $artifacts[12] -Algorithm SHA256).Hash-ne'513F939BB76BC6F478B1CB6130DE139861640A49E074CB9956FE3B73A1B9779C'){Stop-Fail 'GATE5_AUTHORITY_HASH_MISMATCH'}
docker compose config --quiet 1>$null 2>$null
if($LASTEXITCODE-ne 0){Stop-Fail 'COMPOSE_INVALID'}
$db=Get-Inspect 'database';$cache=Get-Inspect 'cache';$directus=Get-Inspect 'directus';$middleware=Get-Inspect 'middleware';$ui=Get-Inspect 'ui'
$health=[ordered]@{database=[string]$db.State.Health.Status;cache=[string]$cache.State.Health.Status;directus=[string]$directus.State.Health.Status;middleware=[string]$middleware.State.Health.Status;ui=[string]$ui.State.Health.Status}
foreach($x in $health.GetEnumerator()){if($x.Value-ne'healthy'){Stop-Fail "SERVICE_NOT_HEALTHY|$($x.Key)|$($x.Value)"}}
$mn=@($middleware.NetworkSettings.Networks.PSObject.Properties.Name)
$un=@($ui.NetworkSettings.Networks.PSObject.Properties.Name)
if('relational-repository_frontend'-notin$mn-or'relational-repository_backend'-in$mn){Stop-Fail 'MIDDLEWARE_NETWORK_BOUNDARY'}
if('relational-repository_frontend'-notin$un-or'relational-repository_backend'-in$un){Stop-Fail 'UI_NETWORK_BOUNDARY'}
$de=@($directus.Config.Env)
if($de-notcontains'DB_USER=directus_runtime'){Stop-Fail 'DIRECTUS_DB_USER'}
if($de-notcontains'DB_SEARCH_PATH=array:reporting,public'){Stop-Fail 'DIRECTUS_SEARCH_PATH'}
if($de-notcontains'DB_PASSWORD_FILE=/run/secrets/directus_runtime_db_password'){Stop-Fail 'DIRECTUS_PASSWORD_FILE'}
if(@($de|Where-Object{$_-like'DB_PASSWORD=*'}).Count-ne 0){Stop-Fail 'DIRECTUS_INLINE_PASSWORD'}
$pm=@($directus.Mounts|Where-Object{$_.Destination-eq'/run/secrets/directus_runtime_db_password'})
if($pm.Count-ne 1-or$pm[0].RW-ne$false){Stop-Fail 'DIRECTUS_PASSWORD_MOUNT'}
if(@($ui.Config.Env|Where-Object{$_-match'(?i)TOKEN|PASSWORD|SECRET|POSTGRES|DB_USER'}).Count-ne 0){Stop-Fail 'UI_SECRET_ENV'}
$hm=Invoke-RestMethod -Uri 'http://127.0.0.1:3001/health' -TimeoutSec 10
if($hm.status-ne'ok'){Stop-Fail 'MIDDLEWARE_HTTP_HEALTH'}
if((Get-Status 'http://127.0.0.1:8080/health')-ne 200){Stop-Fail 'UI_HTTP_HEALTH'}
$fields=@('course_id','university_course_id','course_code','course_title','source_system_code','report_refresh_run_id','report_as_of_utc')
foreach($u in @('http://127.0.0.1:3001/api/courses?limit=1&sort=course_id','http://127.0.0.1:8080/api/courses?limit=1&sort=course_id')){
$b=Invoke-RestMethod -Uri $u -TimeoutSec 15
if($b.ok-ne$true-or@($b.data).Count-ne 1-or[int]$b.meta.total-ne 966){Stop-Fail 'CATALOG_RESPONSE'}
$a=@($b.data[0].PSObject.Properties.Name)
if($a.Count-ne 7-or@($fields|Where-Object{$_-notin$a}).Count-ne 0-or@($a|Where-Object{$_-notin$fields}).Count-ne 0){Stop-Fail 'CATALOG_FIELDS'}
}
$token=[IO.File]::ReadAllText((Resolve-Path '.secrets\wwairml_directus_static_token.txt')).Trim()
if([string]::IsNullOrWhiteSpace($token)){Stop-Fail 'TOKEN_EMPTY'}
$headers=@{Authorization="Bearer $token";Accept='application/json'}
$me=Get-Status 'http://127.0.0.1:8066/users/me' 'GET' $headers
$approved=Get-Status 'http://127.0.0.1:8066/items/course_current_catalog_api?fields=course_id&limit=1' 'GET' $headers
$original=Get-Status 'http://127.0.0.1:8066/items/course_current_catalog?limit=1' 'GET' $headers
$staging=Get-Status 'http://127.0.0.1:8066/items/staging?limit=1' 'GET' $headers
$admin=Get-Status 'http://127.0.0.1:8066/users' 'GET' $headers
$write=Get-Status 'http://127.0.0.1:8066/items/course_current_catalog_api' 'POST' $headers
$token=$null;$headers=$null
if($me-ne 200-or$approved-ne 200){Stop-Fail 'DIRECTUS_APPROVED_PATH'}
foreach($s in @($original,$staging,$admin,$write)){if($s-notin@(403,404)){Stop-Fail "DIRECTUS_NEGATIVE_BOUNDARY|$s"}}
$dbu=(@(docker compose exec -T database printenv POSTGRES_USER 2>$null)-join '').Trim()
$dbn=(@(docker compose exec -T database printenv POSTGRES_DB 2>$null)-join '').Trim()
if([string]::IsNullOrWhiteSpace($dbu)-or[string]::IsNullOrWhiteSpace($dbn)){Stop-Fail 'DATABASE_METADATA'}
$sql="SELECT 'DB_BOUNDARY|schema_usage='||has_schema_privilege('directus_runtime','reporting','USAGE')::text||'|select='||has_table_privilege('directus_runtime','reporting.course_current_catalog_api','SELECT')::text||'|insert='||has_table_privilege('directus_runtime','reporting.course_current_catalog_api','INSERT')::text||'|update='||has_table_privilege('directus_runtime','reporting.course_current_catalog_api','UPDATE')::text||'|delete='||has_table_privilege('directus_runtime','reporting.course_current_catalog_api','DELETE')::text;"
$dbo=(@(docker compose exec -T database psql -X -U $dbu -d $dbn -v ON_ERROR_STOP=1 -qAt -c $sql 2>$null)-join '').Trim()
if($LASTEXITCODE-ne 0-or$dbo-ne'DB_BOUNDARY|schema_usage=true|select=true|insert=false|update=false|delete=false'){Stop-Fail "DATABASE_BOUNDARY|$dbo"}
$manifest=@()
foreach($a in $artifacts){$i=Get-Item -LiteralPath $a;$manifest+=[pscustomobject]@{path=$a;bytes=[int64]$i.Length;algorithm='SHA256';sha256=(Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash}}
New-Item -ItemType Directory -Path $dir -Force|Out-Null
$created=$true
$rp=Join-Path $dir 'gate6-1-prechange-baseline.json'
$mp=Join-Path $dir 'artifact-manifest.json'
$vp=Join-Path $dir 'verification.json'
$sp=Join-Path $dir 'SHA256SUMS.txt'
$record=[ordered]@{project='AIR Course Development Master Hub';gate='Gate 6.1';checkpoint='Pre-change baseline';status='PASS - BASELINE FROZEN';captured_utc=(Get-Date).ToUniversalTime().ToString('o');application_mutated=$false;services_recreated=$false;gates_1_through_5_remain_closed=$true;catalog=[ordered]@{expected_rows=966;observed_total=966;approved_fields=7;middleware_status=200;ui_same_origin_status=200};runtime_health=$health;network_boundary=[ordered]@{ui_frontend=$true;ui_backend=$false;middleware_frontend=$true;middleware_backend=$false};directus_runtime=[ordered]@{db_user='directus_runtime';search_path='reporting,public';password_file=$true;inline_password=$false;approved_read_status=200;internal_collection_denied=$true;staging_denied=$true;admin_denied=$true;write_denied=$true};database_boundary=[ordered]@{schema_usage=$true;select=$true;insert=$false;update=$false;delete=$false};exclusions=@('.secrets/**','credentials and tokens','secret hashes','business row data','container identifiers');authorization='AUTHORIZED TO BEGIN TASK 6.1.2 ONLY AFTER THIS BASELINE PASSES'}
Write-Json $rp $record
Write-Json $mp $manifest
$rh=(Get-FileHash $rp -Algorithm SHA256).Hash
$mh=(Get-FileHash $mp -Algorithm SHA256).Hash
$verification=[ordered]@{verified_utc=(Get-Date).ToUniversalTime().ToString('o');baseline_record_valid_json=$true;artifact_manifest_valid_json=$true;artifact_count=$manifest.Count;artifact_hashes_verified=$true;runtime_controls_verified=$true;security_boundary_verified=$true;secret_contents_included=$false;secret_hashes_included=$false;business_row_data_included=$false;baseline_record_sha256=$rh;artifact_manifest_sha256=$mh;decision='PASS - GATE 6.1 PRE-CHANGE BASELINE FROZEN'}
Write-Json $vp $verification
$null=Get-Content $rp -Raw|ConvertFrom-Json
$null=Get-Content $mp -Raw|ConvertFrom-Json
$null=Get-Content $vp -Raw|ConvertFrom-Json
$vh=(Get-FileHash $vp -Algorithm SHA256).Hash
[IO.File]::WriteAllLines((Join-Path (Get-Location) $sp),@("$rh  gate6-1-prechange-baseline.json","$mh  artifact-manifest.json","$vh  verification.json"),$utf8)
foreach($c in @(@{p=$rp;h=$rh},@{p=$mp;h=$mh},@{p=$vp;h=$vh})){if((Get-FileHash $c.p -Algorithm SHA256).Hash-ne$c.h){Stop-Fail "EVIDENCE_HASH|$($c.p)"}}
$sh=(Get-FileHash $sp -Algorithm SHA256).Hash
Write-Output "PASS|GATE6_1_PRECHANGE_BASELINE_FROZEN|dir=$dir|services=5/5_healthy|catalog_total=966|fields=7|same_origin_proxy=200|approved_read=200|negative_boundaries=true|database_select_only=true|ui_frontend_only=true|middleware_frontend_only=true|artifacts=$($manifest.Count)|record_sha256=$rh|manifest_sha256=$mh|sha256sums_sha256=$sh|runtime_mutated=false|secrets_included=false|business_data_included=false"
}catch{
if($created-and(Test-Path $dir)){Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue}
Write-Output "FAIL|GATE6_1_PRECHANGE_BASELINE|partial_package_removed=$created|runtime_mutated=false|reason=$($_.Exception.Message)"
}finally{
$token=$null
}
