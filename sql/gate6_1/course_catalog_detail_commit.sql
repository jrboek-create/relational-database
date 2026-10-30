\set ON_ERROR_STOP on
BEGIN;

DO $g$
DECLARE v bigint;
BEGIN
  IF current_database() <> 'directus_repository'
     OR current_user <> 'directus_repository' THEN
    RAISE EXCEPTION 'Unexpected database or execution role';
  END IF;

  IF to_regclass('reporting.course_catalog_detail') IS NOT NULL THEN
    RAISE EXCEPTION 'Detail relation already exists';
  END IF;

  SELECT COUNT(*) INTO v
  FROM reporting.course_current_catalog_api;
  IF v <> 966 THEN
    RAISE EXCEPTION 'Frozen API row count changed';
  END IF;

  SELECT COUNT(*) INTO v
  FROM information_schema.columns
  WHERE table_schema='reporting'
    AND table_name='course_current_catalog_api';
  IF v <> 7 THEN
    RAISE EXCEPTION 'Frozen API field count changed';
  END IF;

  SELECT COUNT(*) INTO v
  FROM reporting.projection_refresh_run;
  IF v <> 2 THEN
    RAISE EXCEPTION 'Refresh-run baseline changed';
  END IF;

  SELECT COUNT(*) INTO v
  FROM staging.raw_catalog_ww_2026_09_23_s01_csv_36b98bfb;
  IF v <> 964 THEN
    RAISE EXCEPTION 'Authoritative source count changed';
  END IF;
END
$g$;

CREATE TEMP TABLE detail_candidate ON COMMIT DROP AS
SELECT
  r.course_id,
  r.university_course_id,
  r.course_code,
  r.course_title,
  s.c0005 AS college_name,
  s.c0009 AS course_description,
  s.c0010 AS course_goals,
  s.c0011 AS course_learning_outcomes,
  51::bigint AS source_component_id,
  s.source_hash AS source_file_hash,
  s.import_batch_id AS source_import_batch_id,
  s.source_row_number,
  md5(
    jsonb_build_array(
      r.course_id::text,
      r.university_course_id,
      r.course_code,
      r.course_title,
      s.c0005,
      s.c0009,
      s.c0010,
      s.c0011,
      51,
      s.source_hash,
      s.import_batch_id::text,
      s.source_row_number
    )::text
  ) AS business_row_hash
FROM reporting.course_current_catalog r
JOIN staging.raw_catalog_ww_2026_09_23_s01_csv_36b98bfb s
  ON s.c0001 = r.university_course_id;

DO $g$
DECLARE
  a bigint;
  b bigint;
  c bigint;
  d bigint;
  e bigint;
  f bigint;
BEGIN
  SELECT
    COUNT(*),
    COUNT(DISTINCT course_id),
    COUNT(DISTINCT university_course_id),
    COUNT(*) FILTER (
      WHERE course_id IS NULL
         OR NULLIF(btrim(university_course_id),'') IS NULL
         OR NULLIF(btrim(course_code),'') IS NULL
         OR NULLIF(btrim(course_title),'') IS NULL
         OR NULLIF(btrim(college_name),'') IS NULL
         OR NULLIF(btrim(course_description),'') IS NULL
    ),
    COUNT(*) FILTER (
      WHERE course_goals IS NULL
        AND course_learning_outcomes IS NULL
    ),
    COUNT(*) FILTER (
      WHERE (course_goals IS NULL) <>
            (course_learning_outcomes IS NULL)
    )
  INTO a,b,c,d,e,f
  FROM detail_candidate;

  IF a<>964 OR b<>964 OR c<>964 OR d<>0 OR e<>1 OR f<>0 THEN
    RAISE EXCEPTION 'Candidate assertions failed';
  END IF;
END
$g$;

CREATE TABLE reporting.course_catalog_detail (
  course_id uuid NOT NULL PRIMARY KEY,
  university_course_id text NOT NULL UNIQUE,
  course_code text NOT NULL,
  course_title text NOT NULL,
  college_name text NOT NULL,
  course_description text NOT NULL,
  course_goals text,
  course_learning_outcomes text,
  source_component_id bigint NOT NULL
    CHECK (source_component_id=51),
  source_file_hash text NOT NULL
    CHECK (
      source_file_hash =
      '36b98bfb2418be6bd459fda90b95fd20d2b199b1c878bd75d4b7e0f2456a9c93'
    ),
  source_import_batch_id uuid NOT NULL,
  source_row_number bigint NOT NULL
    CHECK (source_row_number BETWEEN 2 AND 965),
  report_refresh_run_id uuid NOT NULL
    REFERENCES reporting.projection_refresh_run(run_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  report_as_of_utc timestamptz NOT NULL,
  business_row_hash text NOT NULL
    CHECK (business_row_hash ~ '^[0-9a-f]{32}$'),
  CHECK (btrim(university_course_id)<>''),
  CHECK (btrim(course_code)<>''),
  CHECK (btrim(course_title)<>''),
  CHECK (btrim(college_name)<>''),
  CHECK (btrim(course_description)<>'')
);

REVOKE ALL ON reporting.course_catalog_detail FROM PUBLIC;
GRANT SELECT ON reporting.course_catalog_detail TO directus_runtime;
ALTER TABLE reporting.course_catalog_detail OWNER TO air_repository_owner;

CREATE TEMP TABLE detail_context (
  run_id uuid NOT NULL,
  as_of timestamptz NOT NULL
) ON COMMIT DROP;

WITH new_run AS (
  INSERT INTO reporting.projection_refresh_run (
    projection_name,
    source_filter,
    source_state,
    notes
  )
  VALUES (
    'course_catalog_detail',
    jsonb_build_object(
      'source_component_id',51,
      'source_hash',
      '36b98bfb2418be6bd459fda90b95fd20d2b199b1c878bd75d4b7e0f2456a9c93',
      'controlled_test_rows_excluded',2
    ),
    jsonb_build_object(
      'expected_rows',964,
      'expected_null_goals',1,
      'expected_null_learning_outcomes',1
    ),
    'Gate 6.1 rollback rehearsal; no API exposure authorized'
  )
  RETURNING run_id,started_at
)
INSERT INTO detail_context
SELECT run_id,started_at
FROM new_run;

INSERT INTO reporting.course_catalog_detail
SELECT
  c.course_id,
  c.university_course_id,
  c.course_code,
  c.course_title,
  c.college_name,
  c.course_description,
  c.course_goals,
  c.course_learning_outcomes,
  c.source_component_id,
  c.source_file_hash,
  c.source_import_batch_id,
  c.source_row_number,
  x.run_id,
  x.as_of,
  c.business_row_hash
FROM detail_candidate c
CROSS JOIN detail_context x;

WITH checksum AS (
  SELECT md5(
    string_agg(business_row_hash,'' ORDER BY course_id::text)
  ) AS value
  FROM detail_candidate
)
UPDATE reporting.projection_refresh_run r
SET
  completed_at=clock_timestamp(),
  source_row_count=964,
  rows_inserted=964,
  rows_updated=0,
  rows_deleted=0,
  rows_unchanged=0,
  business_checksum=checksum.value,
  status='COMPLETED'
FROM detail_context x
CROSS JOIN checksum
WHERE r.run_id=x.run_id;

DO $g$
DECLARE
  rows_found bigint;
  courses_found bigint;
  university_ids_found bigint;
  null_goals bigint;
  null_outcomes bigint;
  refreshes_found bigint;
  owner_found text;
BEGIN
  SELECT
    COUNT(*),
    COUNT(DISTINCT course_id),
    COUNT(DISTINCT university_course_id),
    COUNT(*) FILTER (WHERE course_goals IS NULL),
    COUNT(*) FILTER (WHERE course_learning_outcomes IS NULL)
  INTO
    rows_found,
    courses_found,
    university_ids_found,
    null_goals,
    null_outcomes
  FROM reporting.course_catalog_detail;

  IF rows_found<>964
     OR courses_found<>964
     OR university_ids_found<>964
     OR null_goals<>1
     OR null_outcomes<>1 THEN
    RAISE EXCEPTION 'Projection assertions failed';
  END IF;

  SELECT COUNT(*) INTO refreshes_found
  FROM reporting.projection_refresh_run r
  JOIN detail_context x ON x.run_id=r.run_id
  WHERE r.projection_name='course_catalog_detail'
    AND r.status='COMPLETED'
    AND r.source_row_count=964
    AND r.rows_inserted=964
    AND r.rows_updated=0
    AND r.rows_deleted=0
    AND r.rows_unchanged=0
    AND r.business_checksum ~ '^[0-9a-f]{32}$';

  IF refreshes_found<>1 THEN
    RAISE EXCEPTION 'Refresh assertion failed';
  END IF;

  SELECT pg_get_userbyid(c.relowner)
  INTO owner_found
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='reporting'
    AND c.relname='course_catalog_detail';

  IF owner_found<>'air_repository_owner' THEN
    RAISE EXCEPTION 'Owner assertion failed';
  END IF;

  IF NOT has_table_privilege(
       'directus_runtime',
       'reporting.course_catalog_detail',
       'SELECT'
     )
     OR has_table_privilege(
       'directus_runtime',
       'reporting.course_catalog_detail',
       'INSERT'
     )
     OR has_table_privilege(
       'directus_runtime',
       'reporting.course_catalog_detail',
       'UPDATE'
     )
     OR has_table_privilege(
       'directus_runtime',
       'reporting.course_catalog_detail',
       'DELETE'
     ) THEN
    RAISE EXCEPTION 'Privilege assertion failed';
  END IF;
END
$g$;

SELECT 'PASS|COMMIT_TRANSACTION_VALIDATED';
SELECT 'REHEARSAL_ROWS|'||COUNT(*)
FROM reporting.course_catalog_detail;
SELECT 'NULL_GOALS|'||
       COUNT(*) FILTER (WHERE course_goals IS NULL)
FROM reporting.course_catalog_detail;
SELECT 'NULL_OUTCOMES|'||
       COUNT(*) FILTER (WHERE course_learning_outcomes IS NULL)
FROM reporting.course_catalog_detail;
SELECT 'FROZEN_API_ROWS|'||COUNT(*)
FROM reporting.course_current_catalog_api;
SELECT 'FROZEN_API_FIELDS|'||COUNT(*)
FROM information_schema.columns
WHERE table_schema='reporting'
  AND table_name='course_current_catalog_api';
COMMIT;