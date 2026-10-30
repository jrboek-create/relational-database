-- Gate 6.2 permission ID 6 one-time wildcard correction COMMIT artifact
-- STATUS: FROZEN ONE-TIME COMMIT ARTIFACT; DO NOT EXECUTE WITHOUT SEPARATE AUTHORIZATION
-- PURPOSE: Change only public.directus_permissions.id=6 fields from the approved explicit eight-field CSV to *.
-- REHEARSAL_SHA256: A8619115C2171BEDEFA7438484A99ED5A9E5DCD12CEF92C821D81E5A27E93A46
-- FROZEN_WRAPPER_COMMIT_SHA256: 5322827707190AF58DA087B0A8876319A457E212D7CA8BEA19D5E29C9D3BB71C
-- ORIGINAL_FIELDS: course_id,university_course_id,course_code,course_title,college_name,course_description,course_goals,course_learning_outcomes
-- ONE-TIME GUARD: after successful execution the explicit-fields precondition no longer matches, so rerun must fail before UPDATE.
-- DETERMINISTIC ROLLBACK STATEMENT IF SEPARATELY AUTHORIZED:
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
    IF (SELECT count(*) FROM public.directus_permissions WHERE id = 1 AND collection = 'course_current_catalog_api' AND action = 'read' AND policy = '6496789e-2aab-44b0-a468-54f4534f065b'::uuid AND fields = '*' AND permissions IS NULL AND validation IS NULL AND presets IS NULL) <> 1 THEN RAISE EXCEPTION 'STOP|FROZEN_PERMISSION_CHANGED'; END IF;
    IF (SELECT count(*) FROM reporting.course_catalog_detail_api) <> 964 THEN RAISE EXCEPTION 'STOP|WRAPPER_CHANGED_DURING_COMMIT'; END IF;
    IF (SELECT count(*) FROM reporting.course_current_catalog_api) <> 966 THEN RAISE EXCEPTION 'STOP|FROZEN_CHANGED_DURING_COMMIT'; END IF;
    RAISE NOTICE 'COMMIT_UPDATE|permission_id=6|rows_updated=%|new_fields=*', v_updated;
END
 $gate62$;
SELECT 'COMMIT_PRECOMMIT_STATE|permission_id=' || id || '|collection=' || collection || '|action=' || action || '|policy=' || policy || '|fields=' || fields FROM public.directus_permissions WHERE id = 6;
COMMIT;
SELECT 'PASS|GATE6_2_PERMISSION6_WILDCARD_COMMIT';
\echo ONE_TIME_PERMISSION6_COMMIT_EXECUTED|TRUE
\echo FROZEN_PERMISSION_1_CHANGED|FALSE
\echo WRAPPER_RELATION_MUTATED|FALSE
