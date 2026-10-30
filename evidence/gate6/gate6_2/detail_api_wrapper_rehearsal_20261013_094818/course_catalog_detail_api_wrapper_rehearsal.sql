BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

DO $gate$
DECLARE v bigint;
BEGIN
    IF to_regclass('reporting.course_catalog_detail_api') IS NOT NULL THEN
        RAISE EXCEPTION 'Wrapper relation already exists';
    END IF;

    SELECT count(*) INTO v FROM reporting.course_catalog_detail;
    IF v <> 964 THEN RAISE EXCEPTION 'Internal detail row count changed'; END IF;

    SELECT count(*) INTO v FROM reporting.course_current_catalog_api;
    IF v <> 966 THEN RAISE EXCEPTION 'Frozen API row count changed'; END IF;

    SELECT count(*) INTO v FROM directus_collections WHERE collection='course_catalog_detail';
    IF v <> 1 THEN RAISE EXCEPTION 'Internal detail collection baseline changed'; END IF;

    SELECT count(*) INTO v FROM directus_permissions WHERE collection='course_catalog_detail';
    IF v <> 1 THEN RAISE EXCEPTION 'Internal detail permission baseline changed'; END IF;

    SELECT count(*) INTO v FROM directus_permissions WHERE collection='course_current_catalog_api';
    IF v <> 1 THEN RAISE EXCEPTION 'Frozen permission baseline changed'; END IF;
END
$gate$;

CREATE TABLE reporting.course_catalog_detail_api (
    course_id uuid NOT NULL,
    university_course_id text,
    course_code text,
    course_title text,
    college_name text,
    course_description text,
    course_goals text,
    course_learning_outcomes text,
    CONSTRAINT course_catalog_detail_api_pkey PRIMARY KEY (course_id)
);

INSERT INTO reporting.course_catalog_detail_api (
    course_id,
    university_course_id,
    course_code,
    course_title,
    college_name,
    course_description,
    course_goals,
    course_learning_outcomes
)
SELECT
    course_id,
    university_course_id,
    course_code,
    course_title,
    college_name,
    course_description,
    course_goals,
    course_learning_outcomes
FROM reporting.course_catalog_detail;

ALTER TABLE reporting.course_catalog_detail_api OWNER TO air_repository_owner;
REVOKE ALL ON TABLE reporting.course_catalog_detail_api FROM PUBLIC;
GRANT SELECT ON TABLE reporting.course_catalog_detail_api TO directus_runtime;

DELETE FROM directus_permissions WHERE collection='course_catalog_detail';
DELETE FROM directus_collections WHERE collection='course_catalog_detail';

INSERT INTO directus_collections (
    collection,icon,note,display_template,hidden,singleton,
    translations,archive_field,archive_app_filter,archive_value,
    unarchive_value,sort_field,accountability,color,
    item_duplication_fields,sort,"group",collapse,preview_url,
    versioning,status,autosave_revision_interval
)
SELECT
    'course_catalog_detail_api',icon,
    'Gate 6.2 governed read-only detail API projection.',
    '{{course_code}} - {{course_title}}',hidden,singleton,
    translations,archive_field,archive_app_filter,archive_value,
    unarchive_value,sort_field,accountability,color,
    item_duplication_fields,sort,"group",collapse,preview_url,
    versioning,status,autosave_revision_interval
FROM directus_collections
WHERE collection='course_current_catalog_api';

INSERT INTO directus_permissions (
    collection,action,permissions,validation,presets,fields,policy
)
SELECT
    'course_catalog_detail_api','read',NULL,NULL,NULL,
    'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes',
    id
FROM directus_policies
WHERE name='Gate 5 Approved Reporting Read Only'
  AND admin_access=false
  AND app_access=false;

DO $gate$
DECLARE
    v bigint;
    fields_found text;
    owner_found text;
BEGIN
    SELECT count(*) INTO v FROM reporting.course_catalog_detail_api;
    IF v <> 964 THEN RAISE EXCEPTION 'Wrapper row count mismatch'; END IF;

    SELECT count(*) INTO v
    FROM (
        SELECT
            count(*) AS rows_found,
            count(DISTINCT course_id) AS course_ids,
            count(DISTINCT university_course_id) AS university_ids,
            count(*) FILTER (WHERE course_goals IS NULL AND course_learning_outcomes IS NULL) AS both_null,
            count(*) FILTER (WHERE (course_goals IS NULL) <> (course_learning_outcomes IS NULL)) AS partial_null
        FROM reporting.course_catalog_detail_api
    ) q
    WHERE rows_found=964 AND course_ids=964 AND university_ids=964
      AND both_null=1 AND partial_null=0;
    IF v <> 1 THEN RAISE EXCEPTION 'Wrapper grain or NULL-semantics mismatch'; END IF;

    SELECT string_agg(column_name,',' ORDER BY ordinal_position) INTO fields_found
    FROM information_schema.columns
    WHERE table_schema='reporting' AND table_name='course_catalog_detail_api';
    IF fields_found <> 'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes' THEN
        RAISE EXCEPTION 'Wrapper field contract mismatch';
    END IF;

    SELECT count(*) INTO v
    FROM pg_constraint con
    JOIN pg_class c ON c.oid=con.conrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='reporting' AND c.relname='course_catalog_detail_api'
      AND con.contype='p' AND pg_get_constraintdef(con.oid,true)='PRIMARY KEY (course_id)';
    IF v <> 1 THEN RAISE EXCEPTION 'Wrapper primary key mismatch'; END IF;

    SELECT pg_get_userbyid(c.relowner) INTO owner_found
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='reporting' AND c.relname='course_catalog_detail_api';
    IF owner_found <> 'air_repository_owner' THEN RAISE EXCEPTION 'Wrapper owner mismatch'; END IF;

    IF NOT has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','SELECT')
       OR has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','INSERT')
       OR has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','UPDATE')
       OR has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','DELETE')
       OR has_table_privilege('directus_runtime','reporting.course_catalog_detail_api','TRUNCATE') THEN
        RAISE EXCEPTION 'Wrapper PostgreSQL privilege mismatch';
    END IF;
END
$gate$;

DO $gate$
DECLARE v bigint; fields_found text;
BEGIN
    SELECT count(*) INTO v FROM directus_collections
    WHERE collection='course_catalog_detail_api' AND hidden=true AND singleton=false;
    IF v <> 1 THEN RAISE EXCEPTION 'Wrapper collection mismatch'; END IF;

    SELECT count(*),min(p.fields) INTO v,fields_found
    FROM directus_permissions p JOIN directus_policies pol ON pol.id=p.policy
    WHERE p.collection='course_catalog_detail_api' AND p.action='read'
      AND p.permissions IS NULL AND p.validation IS NULL AND p.presets IS NULL
      AND pol.name='Gate 5 Approved Reporting Read Only'
      AND pol.admin_access=false AND pol.app_access=false;
    IF v <> 1 OR fields_found <> 'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes' THEN
        RAISE EXCEPTION 'Wrapper read permission mismatch';
    END IF;

    SELECT count(*) INTO v FROM directus_permissions
    WHERE collection='course_catalog_detail_api' AND action<>'read';
    IF v <> 0 THEN RAISE EXCEPTION 'Unexpected wrapper write permission'; END IF;

    SELECT count(*) INTO v FROM directus_fields WHERE collection='course_catalog_detail_api';
    IF v <> 0 THEN RAISE EXCEPTION 'Unexpected wrapper field metadata'; END IF;

    SELECT count(*) INTO v FROM directus_collections WHERE collection='course_catalog_detail';
    IF v <> 0 THEN RAISE EXCEPTION 'Internal detail collection remained registered'; END IF;
    SELECT count(*) INTO v FROM directus_permissions WHERE collection='course_catalog_detail';
    IF v <> 0 THEN RAISE EXCEPTION 'Internal detail permission remained registered'; END IF;

    SELECT count(*) INTO v FROM reporting.course_current_catalog_api;
    IF v <> 966 THEN RAISE EXCEPTION 'Frozen API row count changed'; END IF;
    SELECT count(*) INTO v FROM directus_permissions WHERE collection='course_current_catalog_api';
    IF v <> 1 THEN RAISE EXCEPTION 'Frozen permission count changed'; END IF;
END
$gate$;

SELECT 'PASS|GATE6_2_DETAIL_API_WRAPPER_IN_TRANSACTION';
SELECT 'TX_ROWS|' || count(*) FROM reporting.course_catalog_detail_api;
SELECT 'TX_FIELDS|' || count(*) FROM information_schema.columns WHERE table_schema='reporting' AND table_name='course_catalog_detail_api';
SELECT 'TX_READ_PERMISSIONS|' || count(*) FROM directus_permissions WHERE collection='course_catalog_detail_api' AND action='read';
SELECT 'TX_WRITE_PERMISSIONS|' || count(*) FROM directus_permissions WHERE collection='course_catalog_detail_api' AND action<>'read';
SELECT 'TX_FIELD_METADATA|' || count(*) FROM directus_fields WHERE collection='course_catalog_detail_api';
SELECT 'TX_INTERNAL_COLLECTION|' || count(*) FROM directus_collections WHERE collection='course_catalog_detail';
SELECT 'TX_INTERNAL_PERMISSION|' || count(*) FROM directus_permissions WHERE collection='course_catalog_detail';
SELECT 'TX_FROZEN_ROWS|' || count(*) FROM reporting.course_current_catalog_api;
SELECT 'TX_FROZEN_PERMISSION|' || count(*) FROM directus_permissions WHERE collection='course_current_catalog_api';

ROLLBACK;