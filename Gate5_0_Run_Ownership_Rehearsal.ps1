Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ArtifactDir = "C:\Directus\relational-repository\sql\gate5\ownership_20261002_071029"
$DatabaseContainer = "relational-repository-database-1"
$DirectusContainer = "relational-repository-directus-1"
$CacheContainer = "relational-repository-cache-1"
$DirectusStopped = $false
function Fail {
param([string]$Message)
throw $Message
}
function Count-Pattern {
param([string]$Text,[string]$Pattern)
return [regex]::Matches($Text,$Pattern,[System.Text.RegularExpressions.RegexOptions]::Multiline).Count
}
function Invoke-Psql {
param([string]$Sql)
$Old = $ErrorActionPreference
$Raw = @()
try {
$ErrorActionPreference = "Continue"
$Raw = @($Sql | & docker.exe exec -i $DatabaseContainer sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -q -t -A -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
$Code = $LASTEXITCODE
}
finally {
$ErrorActionPreference = $Old
}
$Lines = @()
foreach ($Item in $Raw) {
foreach ($Line in ([string]$Item -split "`r?`n")) {
$Value = $Line.Trim()
if ($Value.Length -gt 0) { $Lines += $Value }
}
}
if ($Code -ne 0) { Fail ("psql failed with exit code " + $Code + ": " + ($Lines -join " | ")) }
return $Lines
}
function Get-Health {
param([string]$Container)
$Value = @(& docker.exe inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" $Container 2>&1)
if ($LASTEXITCODE -ne 0) { Fail ("Cannot inspect container: " + $Container) }
return ([string]$Value[0]).Trim()
}
function Start-DirectusAndWait {
$null = & docker.exe start $DirectusContainer 2>&1
if ($LASTEXITCODE -ne 0) { Fail "Directus could not be restarted." }
for ($Attempt = 1; $Attempt -le 60; $Attempt++) {
$Health = Get-Health $DirectusContainer
if ($Health -eq "healthy") { return }
Start-Sleep -Seconds 2
}
Fail ("Directus did not return healthy. Last status: " + $Health)
}
function Invoke-Rehearsal {
param([string]$Path)
$SqlText = [System.IO.File]::ReadAllText($Path)
$Old = $ErrorActionPreference
$Raw = @()
try {
$ErrorActionPreference = "Continue"
$Raw = @($SqlText | & docker.exe exec -i $DatabaseContainer sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
$Code = $LASTEXITCODE
}
finally {
$ErrorActionPreference = $Old
}
$Text = ($Raw | ForEach-Object { [string]$_ }) -join "`r`n"
if ($Code -ne 0) { Fail ("Rehearsal psql execution failed with exit code " + $Code + ":`r`n" + $Text) }
if ($Text -notmatch "(?m)^ROLLBACK\s*$") { Fail "Rehearsal output did not contain a successful ROLLBACK command tag." }
if ($Text -match "(?m)^ERROR:") { Fail "Rehearsal output contains a PostgreSQL ERROR." }
return $Text
}
try {
if (-not (Test-Path -LiteralPath $ArtifactDir -PathType Container)) { Fail ("Artifact directory not found: " + $ArtifactDir) }
$ExpectedFiles = @(
"gate5_0_database_owner_forward.sql",
"gate5_0_database_owner_reverse.sql",
"gate5_0_ownership_artifact_manifest.csv",
"gate5_0_ownership_inventory_before.csv",
"gate5_0_targeted_ownership_forward.sql",
"gate5_0_targeted_ownership_rehearsal.sql",
"gate5_0_targeted_ownership_reverse.sql"
) | Sort-Object
$ActualFiles = @(Get-ChildItem -LiteralPath $ArtifactDir -File | Select-Object -ExpandProperty Name | Sort-Object)
$Difference = @(Compare-Object -ReferenceObject $ExpectedFiles -DifferenceObject $ActualFiles)
if ($Difference.Count -ne 0) { Fail ("Artifact file set differs from the required seven files: " + (($Difference | Out-String).Trim())) }
$ForwardPath = Join-Path $ArtifactDir "gate5_0_targeted_ownership_forward.sql"
$RehearsalPath = Join-Path $ArtifactDir "gate5_0_targeted_ownership_rehearsal.sql"
$ReversePath = Join-Path $ArtifactDir "gate5_0_targeted_ownership_reverse.sql"
$DbForwardPath = Join-Path $ArtifactDir "gate5_0_database_owner_forward.sql"
$DbReversePath = Join-Path $ArtifactDir "gate5_0_database_owner_reverse.sql"
$InventoryPath = Join-Path $ArtifactDir "gate5_0_ownership_inventory_before.csv"
$ManifestPath = Join-Path $ArtifactDir "gate5_0_ownership_artifact_manifest.csv"
$Manifest = @(Import-Csv -LiteralPath $ManifestPath)
if ($Manifest.Count -ne 6) { Fail ("Manifest expected 6 rows but contains " + $Manifest.Count) }
$ExpectedManifestNames = @(
"gate5_0_database_owner_forward.sql",
"gate5_0_database_owner_reverse.sql",
"gate5_0_ownership_inventory_before.csv",
"gate5_0_targeted_ownership_forward.sql",
"gate5_0_targeted_ownership_rehearsal.sql",
"gate5_0_targeted_ownership_reverse.sql"
) | Sort-Object
$ManifestNames = @($Manifest | Select-Object -ExpandProperty File | Sort-Object)
if (@(Compare-Object $ExpectedManifestNames $ManifestNames).Count -ne 0) { Fail "Manifest filenames do not match the six required primary artifacts." }
foreach ($Row in $Manifest) {
$Path = Join-Path $ArtifactDir $Row.File
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail ("Manifest file missing: " + $Row.File) }
$Item = Get-Item -LiteralPath $Path
if ([int64]$Row.Bytes -ne $Item.Length) { Fail ("Manifest byte-count mismatch: " + $Row.File) }
$Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
if ($Hash -ne $Row.SHA256) { Fail ("SHA256 mismatch: " + $Row.File) }
}
$Inventory = @(Import-Csv -LiteralPath $InventoryPath)
if ($Inventory.Count -ne 114) { Fail ("Inventory expected 114 rows but contains " + $Inventory.Count) }
if (@($Inventory | Where-Object { $_.CurrentOwner -ne "directus_repository" }).Count -ne 0) { Fail "Before-state inventory contains an unexpected owner." }
$ForwardText = [System.IO.File]::ReadAllText($ForwardPath)
$RehearsalText = [System.IO.File]::ReadAllText($RehearsalPath)
$ReverseText = [System.IO.File]::ReadAllText($ReversePath)
$DbForwardText = [System.IO.File]::ReadAllText($DbForwardPath)
$DbReverseText = [System.IO.File]::ReadAllText($DbReversePath)
$Forbidden = "(?i)\b(REASSIGN\s+OWNED|tiger|tiger_data|topology|spatial_ref_sys)\b"
foreach ($Text in @($ForwardText,$RehearsalText,$ReverseText,$DbForwardText,$DbReverseText)) {
if ($Text -match $Forbidden) { Fail "Prohibited scope found in an ownership artifact." }
}
foreach ($Pair in @(
@("Forward",$ForwardText,"COMMIT;"),
@("Rehearsal",$RehearsalText,"ROLLBACK;"),
@("Reverse",$ReverseText,"COMMIT;")
)) {
$Label = $Pair[0]
$Text = $Pair[1]
$Ending = $Pair[2]
if ((Count-Pattern $Text "^ALTER TABLE ") -ne 96) { Fail ($Label + " table count is not 96.") }
if ((Count-Pattern $Text "^ALTER SEQUENCE ") -ne 12) { Fail ($Label + " sequence count is not 12.") }
if ((Count-Pattern $Text "^ALTER SCHEMA ") -ne 4) { Fail ($Label + " schema count is not 4.") }
if ((Count-Pattern $Text "^ALTER FUNCTION ") -ne 1) { Fail ($Label + " function count is not 1.") }
if (-not $Text.TrimEnd().EndsWith($Ending)) { Fail ($Label + " does not end with " + $Ending) }
}
if ($RehearsalText -match "(?mi)^ALTER DATABASE ") { Fail "Rehearsal contains an ALTER DATABASE statement." }
if ($RehearsalText -match "(?m)^COMMIT;\s*$") { Fail "Rehearsal contains COMMIT." }
if ((Count-Pattern $RehearsalText "^ROLLBACK;\s*$") -ne 1) { Fail "Rehearsal must contain exactly one ROLLBACK." }
if ((Count-Pattern $DbForwardText "^ALTER DATABASE directus_repository OWNER TO air_repository_owner;\s*$") -ne 1) { Fail "Database-owner forward artifact is invalid." }
if ((Count-Pattern $DbReverseText "^ALTER DATABASE directus_repository OWNER TO directus_repository;\s*$") -ne 1) { Fail "Database-owner reverse artifact is invalid." }
$ForwardNormalized = [regex]::Replace($ForwardText.TrimEnd(),"(?m)^COMMIT;\s*$","END;")
$RehearsalNormalized = [regex]::Replace($RehearsalText.TrimEnd(),"(?m)^ROLLBACK;\s*$","END;")
if ($ForwardNormalized -cne $RehearsalNormalized) { Fail "Forward and rehearsal artifacts differ beyond COMMIT versus ROLLBACK." }
$StateSql = @'
SELECT 'schemas=' || count(*) FROM pg_namespace WHERE nspname IN ('core','reporting','staging','phase2_staging') AND pg_get_userbyid(nspowner)='directus_repository';
SELECT 'tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='directus_repository';
SELECT 'sequences=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='S' AND pg_get_userbyid(c.relowner)='directus_repository';
SELECT 'functions=' || count(*) FROM pg_proc WHERE oid=to_regprocedure('staging.assert_row_count(regclass,bigint)') AND pg_get_userbyid(proowner)='directus_repository';
SELECT 'database=' || count(*) FROM pg_database WHERE datname='directus_repository' AND pg_get_userbyid(datdba)='directus_repository';
SELECT 'owner_role_valid=' || count(*) FROM pg_roles WHERE rolname='air_repository_owner' AND NOT rolsuper AND NOT rolcanlogin AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'runtime_role_valid=' || count(*) FROM pg_roles WHERE rolname='directus_runtime' AND NOT rolsuper AND rolcanlogin AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'runtime_owner_membership=' || count(*) FROM pg_auth_members m JOIN pg_roles mr ON mr.oid=m.member JOIN pg_roles gr ON gr.oid=m.roleid WHERE mr.rolname='directus_runtime' AND gr.rolname='air_repository_owner';
'@
$ExpectedState = @("schemas=4","tables=96","sequences=12","functions=1","database=1","owner_role_valid=1","runtime_role_valid=1","runtime_owner_membership=0")
$BeforeState = @(Invoke-Psql $StateSql)
if (@(Compare-Object ($ExpectedState | Sort-Object) ($BeforeState | Sort-Object)).Count -ne 0) { Fail ("Pre-rehearsal ownership state failed: " + ($BeforeState -join ", ")) }
if ((Get-Health $DatabaseContainer) -ne "healthy") { Fail "PostgreSQL is not healthy." }
if ((Get-Health $CacheContainer) -ne "healthy") { Fail "Redis is not healthy." }
if ((Get-Health $DirectusContainer) -ne "healthy") { Fail "Directus is not healthy before rehearsal." }
$null = & docker.exe stop $DirectusContainer 2>&1
if ($LASTEXITCODE -ne 0) { Fail "Directus could not be stopped." }
$DirectusStopped = $true
$SessionCount = @(Invoke-Psql "SELECT count(*) FROM pg_stat_activity WHERE usename='directus_repository' AND backend_type='client backend' AND pid<>pg_backend_pid();")
if ($SessionCount.Count -ne 1 -or $SessionCount[0] -ne "0") { Fail ("Unexpected directus_repository client sessions remain: " + ($SessionCount -join ",")) }
$RehearsalOutput = Invoke-Rehearsal $RehearsalPath
$AfterState = @(Invoke-Psql $StateSql)
if (@(Compare-Object ($ExpectedState | Sort-Object) ($AfterState | Sort-Object)).Count -ne 0) { Fail ("Post-rehearsal ownership state failed: " + ($AfterState -join ", ")) }
if (@(Compare-Object ($BeforeState | Sort-Object) ($AfterState | Sort-Object)).Count -ne 0) { Fail "Pre- and post-rehearsal ownership states differ." }
Start-DirectusAndWait
$DirectusStopped = $false
Write-Host "GATE 5.0 OWNERSHIP REHEARSAL - PASS" -ForegroundColor Green
Write-Host ("ArtifactDirectory=" + $ArtifactDir)
Write-Host "ArtifactReview=PASS"
Write-Host "ManifestVerification=PASS"
Write-Host "RehearsalPsqlExitCode=0"
Write-Host "RehearsalReachedRollback=YES"
Write-Host "PersistentOwnershipChanges=0"
foreach ($Line in $AfterState) { Write-Host $Line }
Write-Host "DatabaseOwnerArtifactExecuted=NO"
Write-Host "ForwardOwnershipArtifactExecuted=NO"
Write-Host "DirectusHealth=healthy"
Write-Host "STOP. DO NOT EXECUTE THE FORWARD SQL." -ForegroundColor Yellow
}
catch {
$OriginalError = $_.Exception.Message
if ($DirectusStopped) {
try {
Start-DirectusAndWait
Write-Host "DirectusRecovery=healthy" -ForegroundColor Yellow
}
catch {
Write-Host ("DirectusRecovery=FAILED: " + $_.Exception.Message) -ForegroundColor Red
}
}
Write-Host "GATE 5.0 OWNERSHIP REHEARSAL - FAILED" -ForegroundColor Red
Write-Host ("Reason=" + $OriginalError) -ForegroundColor Red
Write-Host "FORWARD SQL WAS NOT EXECUTED." -ForegroundColor Yellow
exit 1
}