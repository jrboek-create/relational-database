-- Gate 6.2 permission ID 6 wildcard correction rehearsal
-- STATUS: FROZEN REHEARSAL ONLY; ROLLBACK IS MANDATORY
-- This artifact must not be converted to COMMIT without separate authorization.
-- Changes only public.directus_permissions.id=6 fields from the approved explicit CSV to *.
-- ORIGINAL_FIELDS: course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes
-- DETERMINISTIC COMMITTED-STATE ROLLBACK TEMPLATE:
-- UPDATE public.directus_permissions SET fields = 'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes' WHERE id = 6 AND collection = 'course_catalog_detail_api' AND action = 'read' AND policy = '6496789e-2aab-44b0-a468-54f4534f065b'::uuid AND fields = '*' AND permissions IS NULL AND validation IS NULL AND presets IS NULL;
\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '5s';
DO $gate62$
DECLARE
    v_wrapper_rows bigint;
    v_frozen_rows bigint;
    v_field_count integer;
    v_fields text;
BEGIN
    SELECT count(*) INTO v_wrapper_rows FROM reporting.course_catalog_detail_api;
    IF v_wrapper_rows <> 964 THEN RAISE EXCEPTION 'STOP|WRAPPER_ROW_COUNT_MISMATCH|expected=964|actual=%', v_wrapper_rows; END IF;
    SELECT count(*), string_agg(column_name, ',' ORDER BY ordinal_position)
      INTO v_field_count, v_fields
      FROM information_schema.columns
     WHERE table_schema = 'reporting' AND table_name = 'course_catalog_detail_api';
    IF v_field_count <> 8 THEN RAISE EXCEPTION 'STOP|WRAPPER_FIELD_COUNT_MISMATCH|expected=8|actual=%', v_field_count; END IF;
    IF v_fields <> 'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes' THEN RAISE EXCEPTION 'STOP|WRAPPER_FIELD_CONTRACT_MISMATCH|actual=%', v_fields; END IF;
    IF (SELECT count(*) FROM public.directus_permissions WHERE id = 6 AND collection = 'course_catalog_detail_api' AND action = 'read' AND policy = '6496789e-2aab-44b0-a468-54f4534f065b'::uuid AND fields = 'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes' AND permissions IS NULL AND validation IS NULL AND presets IS NULL) <> 1 THEN RAISE EXCEPTION 'STOP|PERMISSION_6_PRECONDITION_FAILED'; END IF;
    IF (SELECT count(*) FROM public.directus_permissions WHERE collection = 'course_catalog_detail_api' AND action = 'read') <> 1 THEN RAISE EXCEPTION 'STOP|WRAPPER_READ_PERMISSION_COUNT_MISMATCH'; END IF;
    IF EXISTS (SELECT 1 FROM public.directus_permissions WHERE collection = 'course_catalog_detail_api' AND action IN ('create','update','delete','share')) THEN RAISE EXCEPTION 'STOP|WRAPPER_WRITE_PERMISSION_PRESENT'; END IF;
    IF (SELECT count(*) FROM public.directus_fields WHERE collection = 'course_catalog_detail_api') <> 0 THEN RAISE EXCEPTION 'STOP|WRAPPER_DIRECTUS_FIELDS_CHANGED'; END IF;
    SELECT count(*) INTO v_frozen_rows FROM reporting.course_current_catalog_api;
    IF v_frozen_rows <> 966 THEN RAISE EXCEPTION 'STOP|FROZEN_ROW_COUNT_MISMATCH|expected=966|actual=%', v_frozen_rows; END IF;
    IF (SELECT count(*) FROM public.directus_permissions WHERE id = 1 AND collection = 'course_current_catalog_api' AND action = 'read' AND policy = '6496789e-2aab-44b0-a468-54f4534f065b'::uuid AND fields = '*' AND permissions IS NULL AND validation IS NULL AND presets IS NULL) <> 1 THEN RAISE EXCEPTION 'STOP|FROZEN_PERMISSION_PRECONDITION_FAILED'; END IF;
END
 $gate62$;
DO $gate62$
DECLARE
    v_updated bigint;
BEGIN
    UPDATE public.directus_permissions
       SET fields = '*'
     WHERE id = 6
       AND collection = 'course_catalog_detail_api'
       AND action = 'read'
       AND policy = '6496789e-2aab-44b0-a468-54f4534f065b'::uuid
       AND fields = 'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes'
       AND permissions IS NULL
       AND validation IS NULL
       AND presets IS NULL;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated <> 1 THEN RAISE EXCEPTION 'STOP|PERMISSION_6_UPDATE_COUNT|expected=1|actual=%', v_updated; END IF;
    IF (SELECT count(*) FROM public.directus_permissions WHERE id = 6 AND collection = 'course_catalog_detail_api' AND action = 'read' AND policy = '6496789e-2aab-44b0-a468-54f4534f065b'::uuid AND fields = '*' AND permissions IS NULL AND validation IS NULL AND presets IS NULL) <> 1 THEN RAISE EXCEPTION 'STOP|PERMISSION_6_POST_UPDATE_ASSERTION_FAILED'; END IF;
    IF (SELECT count(*) FROM public.directus_permissions WHERE id = 1 AND collection = 'course_current_catalog_api' AND action = 'read' AND fields = '*') <> 1 THEN RAISE EXCEPTION 'STOP|FROZEN_PERMISSION_CHANGED_DURING_REHEARSAL'; END IF;
    RAISE NOTICE 'REHEARSAL_UPDATE|permission_id=6|rows_updated=%|new_fields=*', v_updated;
END
 $gate62$;
SELECT 'REHEARSAL_POST_UPDATE|permission_id=' || id || '|collection=' || collection || '|action=' || action || '|policy=' || policy || '|fields=' || fields FROM public.directus_permissions WHERE id = 6;
ROLLBACK;
BEGIN TRANSACTION READ ONLY;
DO $gate62$
BEGIN
    IF (SELECT count(*) FROM public.directus_permissions WHERE id = 6 AND collection = 'course_catalog_detail_api' AND action = 'read' AND policy = '6496789e-2aab-44b0-a468-54f4534f065b'::uuid AND fields = 'course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes' AND permissions IS NULL AND validation IS NULL AND presets IS NULL) <> 1 THEN RAISE EXCEPTION 'STOP|ROLLBACK_BASELINE_NOT_RESTORED'; END IF;
    IF (SELECT count(*) FROM reporting.course_catalog_detail_api) <> 964 THEN RAISE EXCEPTION 'STOP|WRAPPER_CHANGED_AFTER_ROLLBACK'; END IF;
    IF (SELECT count(*) FROM reporting.course_current_catalog_api) <> 966 THEN RAISE EXCEPTION 'STOP|FROZEN_CHANGED_AFTER_ROLLBACK'; END IF;
END
 $gate62$;
SELECT 'PASS|GATE6_2_PERMISSION6_WILDCARD_REHEARSAL_ROLLBACK';
ROLLBACK;
\echo DATABASE_MUTATED|FALSE
\echo DIRECTUS_METADATA_PERSISTENTLY_MUTATED|FALSE
\echo FROZEN_PERMISSION_1_CHANGED|FALSE
