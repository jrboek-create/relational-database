\set ON_ERROR_STOP on
\pset pager off
\pset null '(null)'
\echo === GATE 5.0 READ-ONLY PREFLIGHT ===
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '120s';

SELECT current_database() AS database_name,
       current_user AS connected_user,
       current_setting('server_version') AS postgres_version,
       current_setting('transaction_read_only') AS transaction_read_only,
       clock_timestamp() AS observed_at_utc;

\echo === APPROVED OBJECT INVENTORY ===
SELECT n.nspname AS schema_name, c.relname AS object_name,
       CASE c.relkind WHEN 'r' THEN 'TABLE' WHEN 'p' THEN 'PARTITIONED TABLE'
        WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'f' THEN 'FOREIGN TABLE' ELSE c.relkind::text END AS object_type,
       pg_get_userbyid(c.relowner) AS owner
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname IN ('core','reporting')
  AND c.relkind IN ('r','p','v','m','f')
ORDER BY 1,2;

\echo === PRIMARY KEYS AND FOREIGN KEYS ===
SELECT n.nspname AS schema_name, c.relname AS table_name, con.conname,
       CASE con.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY' END AS constraint_type,
       pg_get_constraintdef(con.oid) AS definition
FROM pg_constraint con
JOIN pg_class c ON c.oid=con.conrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname IN ('core','reporting') AND con.contype IN ('p','f')
ORDER BY 1,2,4,3;

\echo === DIRECTUS DATABASE ROLE VISIBILITY ===
SELECT 'directus_repository' AS configured_directus_db_user,
       r.rolconfig,
       has_schema_privilege(r.oid,'core','USAGE') AS core_usage,
       has_schema_privilege(r.oid,'reporting','USAGE') AS reporting_usage,
       has_table_privilege(r.oid,'core.course','SELECT') AS core_course_select,
       has_table_privilege(r.oid,'reporting.course_current_catalog','SELECT') AS report_select
FROM pg_roles r WHERE r.rolname='directus_repository';

\echo === TARGET NAME COLLISIONS ACROSS SCHEMAS ===
WITH target(name) AS (VALUES
 ('source_system'),('import_batch'),('organization'),('term'),
 ('lookup_reference_value'),('course'),('person_instructor'),
 ('course_offering_section'),('instructor_assignment'),('faculty_observation'),
 ('feedback_evaluation'),('grade'),('production_activity'),
 ('course_integration'),('redeveloped_course_response'),
 ('course_current_catalog'),('projection_refresh_run'))
SELECT c.relname, string_agg(n.nspname, ', ' ORDER BY n.nspname) AS schemas,
       count(*) AS occurrence_count
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
JOIN target t ON t.name=c.relname
WHERE c.relkind IN ('r','p','v','m','f')
GROUP BY c.relname HAVING count(*) > 1 ORDER BY c.relname;

SELECT (to_regclass('core.course') IS NOT NULL
    AND to_regclass('core.source_system') IS NOT NULL
    AND to_regclass('core.import_batch') IS NOT NULL
    AND to_regclass('reporting.course_current_catalog') IS NOT NULL
    AND to_regclass('reporting.projection_refresh_run') IS NOT NULL) AS gate4_objects_exist
\gset

\if :gate4_objects_exist
\echo === FROZEN GATE 4 BASELINE ===
WITH candidate AS (
 SELECT c.course_id, c.source_identifier AS university_course_id,
        c.course_code, c.course_title, ss.system_code AS source_system_code,
        c.import_batch_id, c.source_record_locator, c.source_version_label
 FROM core.course c
 JOIN core.import_batch ib ON ib.import_batch_id=c.import_batch_id
 JOIN core.source_system ss ON ss.source_system_id=ib.source_system_id
 WHERE upper(trim(ss.system_code))='WW_CATALOG' AND c.is_current IS TRUE
), p AS (
 SELECT * FROM reporting.course_current_catalog
)
SELECT (SELECT count(*) FROM p) AS projection_rows,
       (SELECT count(DISTINCT course_id) FROM p) AS distinct_course_ids,
       (SELECT count(DISTINCT report_refresh_run_id) FROM p) AS distinct_projection_run_ids,
       (SELECT count(DISTINCT report_as_of_utc) FROM p) AS distinct_report_as_of_values,
       (SELECT count(*) FROM candidate) AS candidate_rows,
       (SELECT count(DISTINCT course_id) FROM candidate) AS distinct_candidate_course_ids,
       (SELECT count(*) FROM candidate c LEFT JOIN p USING(course_id)
          WHERE p.course_id IS NULL) AS candidate_missing_from_projection,
       (SELECT count(*) FROM p LEFT JOIN candidate c USING(course_id)
          WHERE c.course_id IS NULL) AS projection_missing_from_candidate,
       (SELECT count(*) FROM p JOIN candidate c USING(course_id)
          WHERE p.university_course_id IS DISTINCT FROM c.university_course_id
             OR p.course_code IS DISTINCT FROM c.course_code
             OR p.course_title IS DISTINCT FROM c.course_title
             OR p.source_system_code IS DISTINCT FROM c.source_system_code
             OR p.core_import_batch_id IS DISTINCT FROM c.import_batch_id
             OR p.source_record_locator IS DISTINCT FROM c.source_record_locator
             OR p.source_version_label IS DISTINCT FROM c.source_version_label)
          AS candidate_projection_business_differences,
       (SELECT count(*) FROM p
          WHERE report_refresh_run_id::text <> '8eec3469-f834-4e90-b695-bb2384cc51e0') AS rows_not_on_accepted_run;

SELECT run_id, projection_name, status, started_at, completed_at,
       source_row_count, rows_inserted, rows_updated, rows_deleted,
       rows_unchanged, business_checksum,
       (business_checksum='666d67d56d4c492ea0cdd7a63a7f85fd') AS checksum_matches_frozen
FROM reporting.projection_refresh_run
WHERE run_id::text='8eec3469-f834-4e90-b695-bb2384cc51e0';

\echo === UNAUTHORIZED REPORTING OBJECT ASSERTIONS ===
SELECT
 (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='reporting' AND c.relkind IN ('r','p','v','m','f','S')
     AND c.relname NOT IN ('course_current_catalog','projection_refresh_run'))
   AS unauthorized_relations,
 (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='reporting') AS reporting_routines,
 (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
   JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='reporting' AND NOT t.tgisinternal) AS user_triggers,
 (SELECT count(*) FROM pg_policy pol JOIN pg_class c ON c.oid=pol.polrelid
   JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='reporting') AS row_policies,
 (SELECT count(*) FROM pg_index i JOIN pg_class idx ON idx.oid=i.indexrelid
   JOIN pg_class tbl ON tbl.oid=i.indrelid
   JOIN pg_namespace n ON n.oid=tbl.relnamespace
   LEFT JOIN pg_constraint con ON con.conindid=idx.oid
   WHERE n.nspname='reporting' AND con.oid IS NULL) AS standalone_indexes;
\else
\echo HOLD: one or more required Gate 4 objects are missing.
\endif

\echo === EXISTING DIRECTUS SYSTEM METADATA ===
SELECT to_regclass('public.directus_collections') IS NOT NULL AS has_directus_collections
\gset
\if :has_directus_collections
WITH target AS (
 SELECT table_schema, table_name FROM information_schema.tables
 WHERE table_schema IN ('core','reporting','staging')
)
SELECT t.table_schema, count(*) AS physical_tables,
       count(dc.collection) AS tables_with_directus_metadata
FROM target t
LEFT JOIN public.directus_collections dc ON dc.collection=t.table_name
GROUP BY t.table_schema ORDER BY t.table_schema;

SELECT collection,
       COALESCE((to_jsonb(dc)->>'hidden')::boolean,false) AS hidden,
       COALESCE(to_jsonb(dc)->>'accountability','') AS accountability,
       COALESCE(to_jsonb(dc)->>'note','') AS note
FROM public.directus_collections dc
WHERE collection IN (
 'source_system','import_batch','organization','term','lookup_reference_value',
 'course','person_instructor','course_offering_section','instructor_assignment',
 'faculty_observation','feedback_evaluation','grade','production_activity',
 'course_integration','redeveloped_course_response',
 'course_current_catalog','projection_refresh_run')
ORDER BY collection;
\else
\echo HOLD: public.directus_collections was not found.
\endif

SELECT to_regclass('public.directus_permissions') IS NOT NULL AS has_directus_permissions
\gset
\if :has_directus_permissions
SELECT COALESCE(to_jsonb(p)->>'policy',to_jsonb(p)->>'role') AS principal_id,
       collection, action,
       COALESCE(to_jsonb(p)->>'fields','<all-or-unspecified>') AS fields,
       CASE WHEN to_jsonb(p)->'permissions' IS NULL THEN '<all>'
            ELSE '<custom>' END AS row_scope
FROM public.directus_permissions p
WHERE collection IN (
 'source_system','import_batch','organization','term','lookup_reference_value',
 'course','person_instructor','course_offering_section','instructor_assignment',
 'faculty_observation','feedback_evaluation','grade','production_activity',
 'course_integration','redeveloped_course_response',
 'course_current_catalog','projection_refresh_run')
   OR collection IN (SELECT table_name FROM information_schema.tables
                     WHERE table_schema='staging')
ORDER BY collection, action, principal_id;
\endif

SELECT to_regclass('public.directus_policies') IS NOT NULL AS has_directus_policies
\gset
\if :has_directus_policies
SELECT id, name,
       COALESCE((to_jsonb(p)->>'admin_access')::boolean,false) AS admin_access,
       COALESCE((to_jsonb(p)->>'app_access')::boolean,false) AS app_access
FROM public.directus_policies p ORDER BY name;
\endif

SELECT to_regclass('public.directus_users') IS NOT NULL AS has_directus_users
\gset
\if :has_directus_users
SELECT COALESCE(to_jsonb(u)->>'status','') AS status,
       COALESCE(to_jsonb(u)->>'role','') AS legacy_role_id,
       count(*) AS user_count,
       count(*) FILTER (WHERE COALESCE(to_jsonb(u)->>'token','') <> '')
          AS users_with_static_token,
       count(*) FILTER (WHERE concat_ws(' ',
          to_jsonb(u)->>'first_name',to_jsonb(u)->>'last_name',
          to_jsonb(u)->>'email') ~* '(service|middleware|api)')
          AS service_identity_name_candidates
FROM public.directus_users u
GROUP BY 1,2 ORDER BY 1,2;
\endif

ROLLBACK;
\echo === END: NO DATABASE CHANGE COMMITTED ===
