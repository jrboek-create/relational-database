Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$SelfPath = $MyInvocation.MyCommand.Path
$ArtifactDir = "C:\Directus\relational-repository\sql\gate5\runtime_privileges_20261002_074331"
$DatabaseContainer = "relational-repository-database-1"
$DirectusContainer = "relational-repository-directus-1"
$CacheContainer = "relational-repository-cache-1"
$EvidenceRoot = "C:\Directus\relational-repository\evidence\gate5"
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$EvidenceDir = Join-Path $EvidenceRoot ("gate5_0_runtime_privileges_commit_" + $Stamp)
$DirectusStopped = $false
$ForwardAttempted = $false
$CommitObserved = $false
function Fail {
param([string]$Message)
throw $Message
}
function Count-Pattern {
param([string]$Text,[string]$Pattern)
return [regex]::Matches($Text,$Pattern,[System.Text.RegularExpressions.RegexOptions]::Multiline).Count
}
function Write-Ascii {
param([string]$Path,[string[]]$Lines)
[System.IO.File]::WriteAllLines($Path,$Lines,[System.Text.Encoding]::ASCII)
}
function Invoke-Psql {
param([string]$Sql)
$OldPreference = $ErrorActionPreference
$Raw = @()
$Code = -1
try {
$ErrorActionPreference = "Continue"
$Raw = @($Sql | & docker.exe exec -i $DatabaseContainer sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -q -t -A -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
$Code = $LASTEXITCODE
}
finally {
$ErrorActionPreference = $OldPreference
}
$Lines = @()
foreach ($Item in $Raw) {
foreach ($Line in ([string]$Item -split "`r?`n")) {
$Value = $Line.Trim()
if ($Value.Length -gt 0) {
$Lines += $Value
}
}
}
if ($Code -ne 0) {
Fail ("psql failed with exit code " + $Code + ": " + ($Lines -join " | "))
}
return $Lines
}
function Assert-State {
param([string[]]$Expected,[string[]]$Actual,[string]$Label)
$Difference = @(Compare-Object ($Expected | Sort-Object) ($Actual | Sort-Object))
if ($Difference.Count -ne 0) {
Fail ($Label + " failed. Observed: " + ($Actual -join ", "))
}
}
function Compare-State {
param([string[]]$Before,[string[]]$After,[string]$Label)
$Difference = @(Compare-Object ($Before | Sort-Object) ($After | Sort-Object))
if ($Difference.Count -ne 0) {
Fail ($Label + " changed: " + (($Difference | Out-String).Trim()))
}
}
function Get-Health {
param([string]$Container)
$Result = @(& docker.exe inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" $Container 2>&1)
if ($LASTEXITCODE -ne 0) {
Fail ("Cannot inspect container: " + $Container)
}
return ([string]$Result[0]).Trim()
}
function Start-DirectusAndWait {
$null = & docker.exe start $DirectusContainer 2>&1
if ($LASTEXITCODE -ne 0) {
Fail "Directus could not be started."
}
for ($Attempt = 1; $Attempt -le 60; $Attempt++) {
$Health = Get-Health $DirectusContainer
if ($Health -eq "healthy") {
return
}
Start-Sleep -Seconds 2
}
Fail ("Directus did not return healthy. Last status: " + $Health)
}
function Invoke-ForwardFile {
param([string]$Path)
$SqlText = [System.IO.File]::ReadAllText($Path)
$OldPreference = $ErrorActionPreference
$Raw = @()
$Code = -1
try {
$ErrorActionPreference = "Continue"
$Raw = @($SqlText | & docker.exe exec -i $DatabaseContainer sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -P pager=off -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' 2>&1)
$Code = $LASTEXITCODE
}
finally {
$ErrorActionPreference = $OldPreference
}
$Text = ($Raw | ForEach-Object { [string]$_ }) -join "`r`n"
if ($Code -ne 0) {
Fail ("Forward privilege transaction failed with exit code " + $Code + ":`r`n" + $Text)
}
if ($Text -match "(?m)^ERROR:") {
Fail "Forward privilege output contains a PostgreSQL ERROR."
}
$CommandTags = [regex]::Matches($Text,"(?m)^(GRANT|REVOKE)\s*$").Count
if ($CommandTags -ne 91) {
Fail ("Expected 91 GRANT/REVOKE command tags but observed " + $CommandTags + ".")
}
if ($Text -notmatch "(?m)^COMMIT\s*$") {
Fail "Forward privilege execution did not report COMMIT."
}
return $Text
}
$PreStateSql = @'
SELECT 'runtime_role_valid=' || count(*) FROM pg_roles WHERE rolname='directus_runtime' AND rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'owner_role_valid=' || count(*) FROM pg_roles WHERE rolname='air_repository_owner' AND NOT rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'runtime_owner_membership=' || count(*) FROM pg_auth_members m JOIN pg_roles mr ON mr.oid=m.member JOIN pg_roles gr ON gr.oid=m.roleid WHERE mr.rolname='directus_runtime' AND gr.rolname='air_repository_owner';
SELECT 'runtime_owned_relations=' || count(*) FROM pg_class WHERE pg_get_userbyid(relowner)='directus_runtime';
SELECT 'owner_schemas=' || count(*) FROM pg_namespace WHERE nspname IN ('core','reporting','staging','phase2_staging') AND pg_get_userbyid(nspowner)='air_repository_owner';
SELECT 'owner_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'owner_sequences=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='S' AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'owner_functions=' || count(*) FROM pg_proc WHERE oid=to_regprocedure('staging.assert_row_count(regclass,bigint)') AND pg_get_userbyid(proowner)='air_repository_owner';
SELECT 'owner_indexes=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='i' AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'database_bootstrap_owner=' || count(*) FROM pg_database WHERE datname='directus_repository' AND pg_get_userbyid(datdba)='directus_repository';
SELECT 'owner_default_acl_entries=' || count(*) FROM pg_default_acl d JOIN pg_roles r ON r.oid=d.defaclrole WHERE r.rolname='air_repository_owner';
SELECT 'runtime_default_acl_entries=' || count(*) FROM pg_default_acl d JOIN pg_roles r ON r.oid=d.defaclrole WHERE r.rolname='directus_runtime';
SELECT 'staging_usage=' || CASE WHEN has_schema_privilege('directus_runtime','staging','USAGE') THEN 1 ELSE 0 END;
SELECT 'phase2_usage=' || CASE WHEN has_schema_privilege('directus_runtime','phase2_staging','USAGE') THEN 1 ELSE 0 END;
SELECT 'staging_table_access=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='staging' AND c.relkind IN ('r','p') AND (has_table_privilege('directus_runtime',c.oid,'SELECT') OR has_table_privilege('directus_runtime',c.oid,'INSERT') OR has_table_privilege('directus_runtime',c.oid,'UPDATE') OR has_table_privilege('directus_runtime',c.oid,'DELETE'));
SELECT 'phase2_table_access=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='phase2_staging' AND c.relkind IN ('r','p') AND (has_table_privilege('directus_runtime',c.oid,'SELECT') OR has_table_privilege('directus_runtime',c.oid,'INSERT') OR has_table_privilege('directus_runtime',c.oid,'UPDATE') OR has_table_privilege('directus_runtime',c.oid,'DELETE'));
SELECT 'public_function_execute=' || CASE WHEN has_function_privilege('public','staging.assert_row_count(regclass,bigint)','EXECUTE') THEN 1 ELSE 0 END;
SELECT 'runtime_function_execute=' || CASE WHEN has_function_privilege('directus_runtime','staging.assert_row_count(regclass,bigint)','EXECUTE') THEN 1 ELSE 0 END;
'@
$ExpectedPreState = @(
"runtime_role_valid=1",
"owner_role_valid=1",
"runtime_owner_membership=0",
"runtime_owned_relations=0",
"owner_schemas=4",
"owner_tables=96",
"owner_sequences=12",
"owner_functions=1",
"owner_indexes=113",
"database_bootstrap_owner=1",
"owner_default_acl_entries=0",
"runtime_default_acl_entries=0",
"staging_usage=0",
"phase2_usage=0",
"staging_table_access=0",
"phase2_table_access=0",
"public_function_execute=1",
"runtime_function_execute=1"
)
$PostStateSql = @'
SELECT 'runtime_role_valid=' || count(*) FROM pg_roles WHERE rolname='directus_runtime' AND rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'owner_role_valid=' || count(*) FROM pg_roles WHERE rolname='air_repository_owner' AND NOT rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
SELECT 'runtime_owner_membership=' || count(*) FROM pg_auth_members m JOIN pg_roles mr ON mr.oid=m.member JOIN pg_roles gr ON gr.oid=m.roleid WHERE mr.rolname='directus_runtime' AND gr.rolname='air_repository_owner';
SELECT 'runtime_owned_relations=' || count(*) FROM pg_class WHERE pg_get_userbyid(relowner)='directus_runtime';
SELECT 'runtime_owned_schemas=' || count(*) FROM pg_namespace WHERE pg_get_userbyid(nspowner)='directus_runtime';
SELECT 'runtime_owned_functions=' || count(*) FROM pg_proc WHERE pg_get_userbyid(proowner)='directus_runtime';
SELECT 'runtime_owned_databases=' || count(*) FROM pg_database WHERE pg_get_userbyid(datdba)='directus_runtime';
SELECT 'owner_schemas=' || count(*) FROM pg_namespace WHERE nspname IN ('core','reporting','staging','phase2_staging') AND pg_get_userbyid(nspowner)='air_repository_owner';
SELECT 'owner_tables=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind IN ('r','p') AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'owner_sequences=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='S' AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'owner_functions=' || count(*) FROM pg_proc WHERE oid=to_regprocedure('staging.assert_row_count(regclass,bigint)') AND pg_get_userbyid(proowner)='air_repository_owner';
SELECT 'owner_indexes=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN ('core','reporting','staging','phase2_staging') OR (n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\')) AND c.relkind='i' AND pg_get_userbyid(c.relowner)='air_repository_owner';
SELECT 'database_bootstrap_owner=' || count(*) FROM pg_database WHERE datname='directus_repository' AND pg_get_userbyid(datdba)='directus_repository';
SELECT 'owner_default_acl_entries=' || count(*) FROM pg_default_acl d JOIN pg_roles r ON r.oid=d.defaclrole WHERE r.rolname='air_repository_owner';
SELECT 'runtime_default_acl_entries=' || count(*) FROM pg_default_acl d JOIN pg_roles r ON r.oid=d.defaclrole WHERE r.rolname='directus_runtime';
SELECT 'database_connect=' || CASE WHEN has_database_privilege('directus_runtime','directus_repository','CONNECT') THEN 1 ELSE 0 END;
SELECT 'database_create=' || CASE WHEN has_database_privilege('directus_runtime','directus_repository','CREATE') THEN 1 ELSE 0 END;
SELECT 'public_usage=' || CASE WHEN has_schema_privilege('directus_runtime','public','USAGE') THEN 1 ELSE 0 END;
SELECT 'core_usage=' || CASE WHEN has_schema_privilege('directus_runtime','core','USAGE') THEN 1 ELSE 0 END;
SELECT 'reporting_usage=' || CASE WHEN has_schema_privilege('directus_runtime','reporting','USAGE') THEN 1 ELSE 0 END;
SELECT 'staging_usage=' || CASE WHEN has_schema_privilege('directus_runtime','staging','USAGE') THEN 1 ELSE 0 END;
SELECT 'phase2_usage=' || CASE WHEN has_schema_privilege('directus_runtime','phase2_staging','USAGE') THEN 1 ELSE 0 END;
SELECT 'schema_create_access=' || count(*) FROM pg_namespace WHERE nspname IN ('public','core','reporting','staging','phase2_staging') AND has_schema_privilege('directus_runtime',oid,'CREATE');
SELECT 'directus_select=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind IN ('r','p') AND has_table_privilege('directus_runtime',c.oid,'SELECT');
SELECT 'directus_insert=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind IN ('r','p') AND has_table_privilege('directus_runtime',c.oid,'INSERT');
SELECT 'directus_update=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind IN ('r','p') AND has_table_privilege('directus_runtime',c.oid,'UPDATE');
SELECT 'directus_delete=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind IN ('r','p') AND has_table_privilege('directus_runtime',c.oid,'DELETE');
SELECT 'directus_forbidden=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind IN ('r','p') AND (has_table_privilege('directus_runtime',c.oid,'TRUNCATE') OR has_table_privilege('directus_runtime',c.oid,'REFERENCES') OR has_table_privilege('directus_runtime',c.oid,'TRIGGER') OR has_table_privilege('directus_runtime',c.oid,'MAINTAIN'));
SELECT 'core_select=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='core' AND c.relkind IN ('r','p') AND has_table_privilege('directus_runtime',c.oid,'SELECT');
SELECT 'core_write=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='core' AND c.relkind IN ('r','p') AND (has_table_privilege('directus_runtime',c.oid,'INSERT') OR has_table_privilege('directus_runtime',c.oid,'UPDATE') OR has_table_privilege('directus_runtime',c.oid,'DELETE') OR has_table_privilege('directus_runtime',c.oid,'TRUNCATE') OR has_table_privilege('directus_runtime',c.oid,'REFERENCES') OR has_table_privilege('directus_runtime',c.oid,'TRIGGER') OR has_table_privilege('directus_runtime',c.oid,'MAINTAIN'));
SELECT 'reporting_select=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='reporting' AND c.relkind IN ('r','p') AND has_table_privilege('directus_runtime',c.oid,'SELECT');
SELECT 'reporting_write=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='reporting' AND c.relkind IN ('r','p') AND (has_table_privilege('directus_runtime',c.oid,'INSERT') OR has_table_privilege('directus_runtime',c.oid,'UPDATE') OR has_table_privilege('directus_runtime',c.oid,'DELETE') OR has_table_privilege('directus_runtime',c.oid,'TRUNCATE') OR has_table_privilege('directus_runtime',c.oid,'REFERENCES') OR has_table_privilege('directus_runtime',c.oid,'TRIGGER') OR has_table_privilege('directus_runtime',c.oid,'MAINTAIN'));
SELECT 'directus_sequence_usage=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind='S' AND CASE WHEN c.relkind='S' THEN has_sequence_privilege('directus_runtime',c.oid,'USAGE') ELSE false END;
SELECT 'directus_sequence_select=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind='S' AND CASE WHEN c.relkind='S' THEN has_sequence_privilege('directus_runtime',c.oid,'SELECT') ELSE false END;
SELECT 'directus_sequence_update=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'directus\_%' ESCAPE '\' AND c.relkind='S' AND CASE WHEN c.relkind='S' THEN has_sequence_privilege('directus_runtime',c.oid,'UPDATE') ELSE false END;
SELECT 'staging_table_access=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='staging' AND c.relkind IN ('r','p') AND (has_table_privilege('directus_runtime',c.oid,'SELECT') OR has_table_privilege('directus_runtime',c.oid,'INSERT') OR has_table_privilege('directus_runtime',c.oid,'UPDATE') OR has_table_privilege('directus_runtime',c.oid,'DELETE') OR has_table_privilege('directus_runtime',c.oid,'TRUNCATE') OR has_table_privilege('directus_runtime',c.oid,'REFERENCES') OR has_table_privilege('directus_runtime',c.oid,'TRIGGER') OR has_table_privilege('directus_runtime',c.oid,'MAINTAIN'));
SELECT 'phase2_table_access=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='phase2_staging' AND c.relkind IN ('r','p') AND (has_table_privilege('directus_runtime',c.oid,'SELECT') OR has_table_privilege('directus_runtime',c.oid,'INSERT') OR has_table_privilege('directus_runtime',c.oid,'UPDATE') OR has_table_privilege('directus_runtime',c.oid,'DELETE') OR has_table_privilege('directus_runtime',c.oid,'TRUNCATE') OR has_table_privilege('directus_runtime',c.oid,'REFERENCES') OR has_table_privilege('directus_runtime',c.oid,'TRIGGER') OR has_table_privilege('directus_runtime',c.oid,'MAINTAIN'));
SELECT 'staging_sequence_access=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='staging' AND c.relkind='S' AND (has_sequence_privilege('directus_runtime',c.oid,'USAGE') OR has_sequence_privilege('directus_runtime',c.oid,'SELECT') OR has_sequence_privilege('directus_runtime',c.oid,'UPDATE'));
SELECT 'phase2_sequence_access=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='phase2_staging' AND c.relkind='S' AND (has_sequence_privilege('directus_runtime',c.oid,'USAGE') OR has_sequence_privilege('directus_runtime',c.oid,'SELECT') OR has_sequence_privilege('directus_runtime',c.oid,'UPDATE'));
SELECT 'public_function_execute=' || CASE WHEN has_function_privilege('public','staging.assert_row_count(regclass,bigint)','EXECUTE') THEN 1 ELSE 0 END;
SELECT 'runtime_function_execute=' || CASE WHEN has_function_privilege('directus_runtime','staging.assert_row_count(regclass,bigint)','EXECUTE') THEN 1 ELSE 0 END;
'@
$ExpectedPostState = @(
"runtime_role_valid=1",
"owner_role_valid=1",
"runtime_owner_membership=0",
"runtime_owned_relations=0",
"runtime_owned_schemas=0",
"runtime_owned_functions=0",
"runtime_owned_databases=0",
"owner_schemas=4",
"owner_tables=96",
"owner_sequences=12",
"owner_functions=1",
"owner_indexes=113",
"database_bootstrap_owner=1",
"owner_default_acl_entries=0",
"runtime_default_acl_entries=0",
"database_connect=1",
"database_create=0",
"public_usage=1",
"core_usage=1",
"reporting_usage=1",
"staging_usage=0",
"phase2_usage=0",
"schema_create_access=0",
"directus_select=33",
"directus_insert=33",
"directus_update=33",
"directus_delete=33",
"directus_forbidden=0",
"core_select=15",
"core_write=0",
"reporting_select=2",
"reporting_write=0",
"directus_sequence_usage=8",
"directus_sequence_select=8",
"directus_sequence_update=0",
"staging_table_access=0",
"phase2_table_access=0",
"staging_sequence_access=0",
"phase2_sequence_access=0",
"public_function_execute=0",
"runtime_function_execute=0"
)
$Gate4Sql = @'
SELECT 'report_rows=' || count(*) FROM reporting.course_current_catalog;
SELECT 'report_distinct_course_ids=' || count(DISTINCT course_id) FROM reporting.course_current_catalog;
SELECT 'projection_runs=' || count(DISTINCT report_refresh_run_id) FROM reporting.course_current_catalog;
SELECT 'report_as_of_values=' || count(DISTINCT report_as_of_utc) FROM reporting.course_current_catalog;
SELECT 'core_current_rows=' || count(*) FROM core.course WHERE is_current IS TRUE;
SELECT 'core_distinct_course_ids=' || count(DISTINCT course_id) FROM core.course WHERE is_current IS TRUE;
SELECT 'required_failures=' || count(*) FILTER (WHERE course_id IS NULL OR source_identifier IS NULL OR btrim(source_identifier)='' OR course_code IS NULL OR btrim(course_code)='' OR course_title IS NULL OR btrim(course_title)='' OR import_batch_id IS NULL) FROM core.course WHERE is_current IS TRUE;
SELECT 'duplicate_source_groups=' || count(*) FROM (SELECT source_identifier FROM core.course WHERE is_current IS TRUE GROUP BY source_identifier HAVING count(*)>1) d;
SELECT 'second_batch=' || count(*) FROM core.course WHERE is_current IS TRUE AND import_batch_id='53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid;
SELECT 'prior_batch=' || count(*) FROM core.course WHERE is_current IS TRUE AND import_batch_id='06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid;
SELECT 'other_batches=' || count(*) FROM core.course WHERE is_current IS TRUE AND import_batch_id NOT IN ('53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,'06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid);
SELECT 'accepted_run=' || run_id::text || '|' || status || '|' || source_row_count::text || '|' || rows_inserted::text || '|' || rows_updated::text || '|' || rows_deleted::text || '|' || rows_unchanged::text || '|' || business_checksum FROM reporting.projection_refresh_run WHERE run_id='8eec3469-f834-4e90-b695-bb2384cc51e0'::uuid;
SELECT 'primary_keys=' || count(*) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('core','reporting') AND con.contype='p';
SELECT 'foreign_keys=' || count(*) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('core','reporting') AND con.contype='f';
SELECT 'directus_collections=' || count(*) FROM public.directus_collections;
SELECT 'directus_fields=' || count(*) FROM public.directus_fields;
SELECT 'directus_relations=' || count(*) FROM public.directus_relations;
SELECT 'directus_permissions=' || count(*) FROM public.directus_permissions;
'@
$ExpectedGate4 = @(
"report_rows=966",
"report_distinct_course_ids=966",
"projection_runs=1",
"report_as_of_values=1",
"core_current_rows=966",
"core_distinct_course_ids=966",
"required_failures=0",
"duplicate_source_groups=0",
"second_batch=5",
"prior_batch=961",
"other_batches=0",
"accepted_run=8eec3469-f834-4e90-b695-bb2384cc51e0|COMPLETED|966|0|0|0|966|666d67d56d4c492ea0cdd7a63a7f85fd",
"primary_keys=17",
"foreign_keys=56",
"directus_collections=0",
"directus_fields=0",
"directus_relations=0",
"directus_permissions=0"
)
$ExcludedSql = @'
SELECT 'SCHEMA|' || nspname || '|' || pg_get_userbyid(nspowner) || '|' || coalesce(nspacl::text,'NULL') FROM pg_namespace WHERE nspname IN ('tiger','tiger_data','topology')
UNION ALL
SELECT 'RELATION|' || n.nspname || '|' || c.relkind::text || '|' || c.relname || '|' || pg_get_userbyid(c.relowner) || '|' || coalesce(c.relacl::text,'NULL') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('tiger','tiger_data','topology') OR (n.nspname='public' AND c.relname='spatial_ref_sys')
UNION ALL
SELECT 'EXTENSION|' || extname || '|' || pg_get_userbyid(extowner) FROM pg_extension
UNION ALL
SELECT 'EXTENSION_RELATION|' || n.nspname || '|' || c.relname || '|' || pg_get_userbyid(c.relowner) || '|' || coalesce(c.relacl::text,'NULL') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_depend d ON d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e' JOIN pg_extension e ON e.oid=d.refobjid
UNION ALL
SELECT 'EXTENSION_FUNCTION|' || n.nspname || '|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || pg_get_userbyid(p.proowner) || '|' || coalesce(p.proacl::text,'NULL') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_depend d ON d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e' JOIN pg_extension e ON e.oid=d.refobjid
ORDER BY 1;
'@
try {
$SelfBad = @([System.IO.File]::ReadAllBytes($SelfPath) | Where-Object { $_ -gt 127 })
if ($SelfBad.Count -ne 0) {
Fail ("Runner contains " + $SelfBad.Count + " non-ASCII bytes.")
}
$ExpectedFiles = @(
"gate5_0_runtime_privileges_before.csv",
"gate5_0_runtime_privileges_forward.sql",
"gate5_0_runtime_privileges_manifest.csv",
"gate5_0_runtime_privileges_rehearsal.sql",
"gate5_0_runtime_privileges_reverse.sql"
) | Sort-Object
$ActualFiles = @(Get-ChildItem -LiteralPath $ArtifactDir -File | Select-Object -ExpandProperty Name | Sort-Object)
if (@(Compare-Object $ExpectedFiles $ActualFiles).Count -ne 0) {
Fail "Authoritative privilege artifact file set changed."
}
$ForwardPath = Join-Path $ArtifactDir "gate5_0_runtime_privileges_forward.sql"
$ManifestPath = Join-Path $ArtifactDir "gate5_0_runtime_privileges_manifest.csv"
$Manifest = @(Import-Csv -LiteralPath $ManifestPath)
if ($Manifest.Count -ne 4) {
Fail "Privilege manifest does not contain four primary artifacts."
}
foreach ($Row in $Manifest) {
$Path = Join-Path $ArtifactDir $Row.File
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
Fail ("Manifest file missing: " + $Row.File)
}
if ((Get-Item -LiteralPath $Path).Length -ne [int64]$Row.Bytes) {
Fail ("Manifest byte count mismatch: " + $Row.File)
}
if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Row.SHA256) {
Fail ("Manifest SHA256 mismatch: " + $Row.File)
}
}
$ForwardText = [System.IO.File]::ReadAllText($ForwardPath)
if ((Count-Pattern $ForwardText "^(GRANT|REVOKE) ") -ne 91) {
Fail "Forward artifact does not contain exactly 91 GRANT/REVOKE statements."
}
if ((Count-Pattern $ForwardText "^BEGIN;\s*$") -ne 1) {
Fail "Forward artifact does not contain exactly one BEGIN."
}
if ((Count-Pattern $ForwardText "^COMMIT;\s*$") -ne 1) {
Fail "Forward artifact does not contain exactly one COMMIT."
}
if (-not $ForwardText.TrimEnd().EndsWith("COMMIT;")) {
Fail "Forward artifact does not end with COMMIT."
}
$Forbidden = "(?im)^(ALTER|CREATE|DROP|INSERT|UPDATE|DELETE|TRUNCATE|COPY|PASSWORD|REASSIGN)\b|ALTER\s+DATABASE|ALTER\s+DEFAULT\s+PRIVILEGES|OWNER\s+TO|REASSIGN\s+OWNED|tiger_data|tiger|topology|spatial_ref_sys"
if ($ForwardText -match $Forbidden) {
Fail "Forward privilege artifact contains prohibited SQL or scope."
}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$BeforeState = @(Invoke-Psql $PreStateSql)
Assert-State $ExpectedPreState $BeforeState "Pre-transfer privilege and ownership state"
$BeforeGate4 = @(Invoke-Psql $Gate4Sql)
Assert-State $ExpectedGate4 $BeforeGate4 "Pre-transfer Gate 4 baseline"
$ExcludedBefore = @(Invoke-Psql $ExcludedSql)
if ($ExcludedBefore.Count -eq 0) {
Fail "Excluded-object snapshot is empty."
}
Write-Ascii (Join-Path $EvidenceDir "pre_state.txt") $BeforeState
Write-Ascii (Join-Path $EvidenceDir "pre_gate4.txt") $BeforeGate4
Write-Ascii (Join-Path $EvidenceDir "excluded_before.txt") $ExcludedBefore
if ((Get-Health $DatabaseContainer) -ne "healthy") {
Fail "PostgreSQL is not healthy."
}
if ((Get-Health $CacheContainer) -ne "healthy") {
Fail "Redis is not healthy."
}
if ((Get-Health $DirectusContainer) -ne "healthy") {
Fail "Directus is not healthy before privilege transfer."
}
$null = & docker.exe stop $DirectusContainer 2>&1
if ($LASTEXITCODE -ne 0) {
Fail "Directus could not be stopped."
}
$DirectusStopped = $true
$Sessions = @(Invoke-Psql "SELECT count(*) FROM pg_stat_activity WHERE usename='directus_repository' AND backend_type='client backend' AND pid<>pg_backend_pid();")
if ($Sessions.Count -ne 1 -or $Sessions[0] -ne "0") {
Fail ("Unexpected directus_repository client sessions remain: " + ($Sessions -join ","))
}
$ForwardAttempted = $true
$ForwardOutput = Invoke-ForwardFile $ForwardPath
$CommitObserved = $true
Write-Ascii (Join-Path $EvidenceDir "forward_psql_output.txt") @($ForwardOutput -split "`r?`n")
$AfterState = @(Invoke-Psql $PostStateSql)
Assert-State $ExpectedPostState $AfterState "Committed runtime privilege state"
Write-Ascii (Join-Path $EvidenceDir "post_state.txt") $AfterState
$AfterGate4 = @(Invoke-Psql $Gate4Sql)
Assert-State $ExpectedGate4 $AfterGate4 "Post-transfer Gate 4 baseline"
Compare-State $BeforeGate4 $AfterGate4 "Gate 4 pre/post comparison"
Write-Ascii (Join-Path $EvidenceDir "post_gate4.txt") $AfterGate4
$ExcludedAfter = @(Invoke-Psql $ExcludedSql)
Compare-State $ExcludedBefore $ExcludedAfter "Excluded extension and PostGIS state"
Write-Ascii (Join-Path $EvidenceDir "excluded_after.txt") $ExcludedAfter
Start-DirectusAndWait
$DirectusStopped = $false
$EvidenceFiles = @(Get-ChildItem -LiteralPath $EvidenceDir -File)
$EvidenceManifest = @()
foreach ($File in $EvidenceFiles) {
$EvidenceManifest += [pscustomobject]@{
File = $File.Name
Bytes = $File.Length
SHA256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
}
}
$EvidenceManifest | Export-Csv -LiteralPath (Join-Path $EvidenceDir "evidence_manifest.csv") -NoTypeInformation -Encoding ASCII
Write-Host "GATE 5.0 COMMITTED RUNTIME PRIVILEGE TRANSFER - PASS" -ForegroundColor Green
Write-Host ("ArtifactDirectory=" + $ArtifactDir)
Write-Host ("EvidenceDirectory=" + $EvidenceDir)
Write-Host "ManifestVerification=PASS"
Write-Host "PrivilegeStatementsCommitted=91"
Write-Host "ForwardPsqlExitCode=0"
Write-Host "ForwardReachedCommit=YES"
foreach ($Line in $AfterState) {
Write-Host $Line
}
Write-Host "ExcludedOwnershipAndAclChanges=0"
Write-Host "Gate4Baseline=PASS"
Write-Host "DatabaseOwner=directus_repository"
Write-Host "DefaultPrivilegesChanged=NO"
Write-Host "DirectusHealth=healthy"
Write-Host "DirectusCredentialsChanged=NO"
Write-Host "DirectusAuthorizationReadiness=NOT_YET_TESTED"
Write-Host "ReversePrivilegeArtifactExecuted=NO"
Write-Host "STOP. DO NOT CHANGE DATABASE OWNER OR DIRECTUS CREDENTIALS YET." -ForegroundColor Yellow
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
Write-Host "GATE 5.0 COMMITTED RUNTIME PRIVILEGE TRANSFER - FAILED" -ForegroundColor Red
Write-Host ("ForwardAttempted=" + $ForwardAttempted)
Write-Host ("CommitObserved=" + $CommitObserved)
Write-Host ("Reason=" + $OriginalError) -ForegroundColor Red
try {
$FailureState = @(Invoke-Psql $PostStateSql)
Write-Host "CurrentPrivilegeState:"
foreach ($Line in $FailureState) {
Write-Host $Line
}
if (Test-Path -LiteralPath $EvidenceDir) {
Write-Ascii (Join-Path $EvidenceDir "failure_state.txt") $FailureState
}
}
catch {
Write-Host ("FailureStateQuery=FAILED: " + $_.Exception.Message) -ForegroundColor Red
}
Write-Host "REVERSE PRIVILEGE SQL WAS NOT AUTOMATICALLY EXECUTED." -ForegroundColor Yellow
Write-Host "DATABASE OWNER, PASSWORDS, AND DIRECTUS CONFIGURATION WERE NOT CHANGED." -ForegroundColor Yellow
exit 1
}