\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset fieldsep '|'

BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';

DO $gate$
DECLARE
    v bigint;
    v_fields text;
BEGIN
    IF current_database()<>'directus_repository'
       OR current_user<>'directus_repository' THEN
        RAISE EXCEPTION 'Unexpected database or role';
    END IF;

    IF to_regclass('reporting.course_catalog_detail') IS NULL THEN
        RAISE EXCEPTION 'Physical detail table is missing';
    END IF;

    IF EXISTS (
        SELECT 1 FROM directus_collections
        WHERE collection='course_catalog_detail'
    ) THEN
        RAISE EXCEPTION 'Detail collection is already registered';
    END IF;

    IF EXISTS (
        SELECT 1 FROM directus_permissions
        WHERE collection='course_catalog_detail'
    ) THEN
        RAISE EXCEPTION 'Detail permission already exists';
    END IF;

    SELECT count(*) INTO v
    FROM directus_collections
    WHERE collection='course_current_catalog_api';

    IF v<>1 THEN
        RAISE EXCEPTION 'Frozen collection baseline mismatch';
    END IF;

    SELECT count(*) INTO v
    FROM directus_permissions p
    JOIN directus_policies pol ON pol.id=p.policy
    WHERE p.collection='course_current_catalog_api'
      AND p.action='read'
      AND p.fields='*'
      AND pol.name='Gate 5 Approved Reporting Read Only';

    IF v<>1 THEN
        RAISE EXCEPTION 'Frozen permission baseline mismatch';
    END IF;

    SELECT count(*) INTO v
    FROM directus_policies
    WHERE name='Gate 5 Approved Reporting Read Only'
      AND admin_access=false
      AND app_access=false;

    IF v<>1 THEN
        RAISE EXCEPTION 'Approved policy mismatch';
    END IF;

    SELECT count(*) INTO v
    FROM directus_access a
    JOIN directus_policies p ON p.id=a.policy
    JOIN directus_roles r ON r.id=a.role
    WHERE p.name='Gate 5 Approved Reporting Read Only'
      AND r.name='Gate 5 API Service';

    IF v<>1 THEN
        RAISE EXCEPTION 'Policy-role assignment mismatch';
    END IF;

    SELECT count(*) INTO v
    FROM directus_users u
    JOIN directus_roles r ON r.id=u.role
    WHERE lower(u.email)='wwairml@erau.edu'
      AND u.status='active'
      AND r.name='Gate 5 API Service';

    IF v<>1 THEN
        RAISE EXCEPTION 'Service identity mismatch';
    END IF;

    SELECT string_agg(column_name,',' ORDER BY ordinal_position)
    INTO v_fields
    FROM information_schema.columns
    WHERE table_schema='reporting'
      AND table_name='course_catalog_detail';

    IF v_fields<>
       'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes,source_component_id,source_file_hash,source_import_batch_id,source_row_number,report_refresh_run_id,report_as_of_utc,business_row_hash' THEN
        RAISE EXCEPTION 'Physical detail-field contract mismatch';
    END IF;
END
$gate$;

INSERT INTO directus_collections (
    collection,icon,note,display_template,hidden,singleton,
    translations,archive_field,archive_app_filter,archive_value,
    unarchive_value,sort_field,accountability,color,
    item_duplication_fields,sort,"group",collapse,preview_url,
    versioning,status,autosave_revision_interval
)
SELECT
    'course_catalog_detail',
    icon,
    'Gate 6.2 governed read-only course-detail projection; API exposure limited by explicit field permission.',
    '{{course_code}} - {{course_title}}',
    true,
    singleton,
    translations,
    archive_field,
    archive_app_filter,
    archive_value,
    unarchive_value,
    sort_field,
    accountability,
    color,
    item_duplication_fields,
    sort,
    "group",
    collapse,
    preview_url,
    versioning,
    status,
    autosave_revision_interval
FROM directus_collections
WHERE collection='course_current_catalog_api';

INSERT INTO directus_permissions (
    collection,action,permissions,validation,presets,fields,policy
)
SELECT
    'course_catalog_detail',
    'read',
    NULL,
    NULL,
    NULL,
    'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes',
    id
FROM directus_policies
WHERE name='Gate 5 Approved Reporting Read Only'
  AND admin_access=false
  AND app_access=false;

DO $gate$
DECLARE
    v bigint;
    v_fields text;
BEGIN
    SELECT count(*) INTO v
    FROM directus_collections
    WHERE collection='course_catalog_detail'
      AND hidden=true
      AND singleton=false
      AND versioning=false
      AND accountability='all';

    IF v<>1 THEN
        RAISE EXCEPTION 'Rehearsed collection metadata mismatch';
    END IF;

    SELECT count(*),min(p.fields)
    INTO v,v_fields
    FROM directus_permissions p
    JOIN directus_policies pol ON pol.id=p.policy
    WHERE p.collection='course_catalog_detail'
      AND p.action='read'
      AND p.permissions IS NULL
      AND p.validation IS NULL
      AND p.presets IS NULL
      AND pol.name='Gate 5 Approved Reporting Read Only';

    IF v<>1 OR v_fields<>
       'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes' THEN
        RAISE EXCEPTION 'Explicit field permission mismatch';
    END IF;

    SELECT count(*) INTO v
    FROM directus_permissions
    WHERE collection='course_catalog_detail'
      AND action<>'read';

    IF v<>0 THEN
        RAISE EXCEPTION 'Unexpected write permission rehearsed';
    END IF;

    SELECT count(*) INTO v
    FROM directus_fields
    WHERE collection='course_catalog_detail';

    IF v<>0 THEN
        RAISE EXCEPTION 'Unexpected explicit field metadata created';
    END IF;

    SELECT count(*) INTO v
    FROM directus_permissions
    WHERE collection='course_current_catalog_api';

    IF v<>1 THEN
        RAISE EXCEPTION 'Frozen collection permission changed';
    END IF;
END
$gate$;

SELECT 'PASS|GATE6_2_DIRECTUS_DETAIL_METADATA_PERMISSION_COMMIT_VALIDATED';
SELECT 'REHEARSED_COLLECTION_ROWS|'||count(*)
FROM directus_collections
WHERE collection='course_catalog_detail';
SELECT 'REHEARSED_READ_PERMISSION_ROWS|'||count(*)
FROM directus_permissions
WHERE collection='course_catalog_detail' AND action='read';
SELECT 'REHEARSED_WRITE_PERMISSION_ROWS|'||count(*)
FROM directus_permissions
WHERE collection='course_catalog_detail' AND action<>'read';
SELECT 'REHEARSED_FIELD_METADATA_ROWS|'||count(*)
FROM directus_fields
WHERE collection='course_catalog_detail';
SELECT 'FROZEN_COLLECTION_PERMISSION_ROWS|'||count(*)
FROM directus_permissions
WHERE collection='course_current_catalog_api';
COMMIT;