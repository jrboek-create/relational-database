-- Directus Relational Repository
-- Gate 4.1 read-only preflight: Current WW_CATALOG Course Catalog
-- No Gate 4.2 structures, raw-staging reads, or Gate 3 promotion calls.

BEGIN;
SET TRANSACTION READ ONLY;

-- 1. PostgreSQL environment and transaction protection.
SELECT current_database() AS database_name,
       current_user AS database_user,
       current_setting('server_version') AS postgres_version,
       current_setting('transaction_read_only') AS transaction_read_only,
       current_setting('transaction_isolation') AS transaction_isolation,
       pg_is_in_recovery() AS server_is_in_recovery,
       clock_timestamp() AS observed_at;

-- 2. Required schemas. reporting is informational and is not expected yet.
SELECT v.schema_name,
       EXISTS (
           SELECT 1
           FROM information_schema.schemata s
           WHERE s.schema_name = v.schema_name
       ) AS schema_exists,
       v.expectation
FROM (VALUES
    ('core'::text, 'REQUIRED'),
    ('staging'::text, 'REQUIRED'),
    ('reporting'::text, 'INFORMATIONAL_NOT_EXPECTED_YET')
) v(schema_name, expectation)
ORDER BY v.schema_name;

-- 3. Exact live column inventories.
SELECT table_schema,
       table_name,
       ordinal_position,
       column_name,
       data_type,
       udt_name,
       is_nullable,
       column_default
FROM information_schema.columns
WHERE table_schema = 'core'
  AND table_name IN ('course','import_batch','source_system')
ORDER BY table_name, ordinal_position;

-- 4. Expected-column reconciliation.
WITH expected(table_name,column_name) AS (
    VALUES
      ('course','course_id'),
      ('course','course_code'),
      ('course','course_title'),
      ('course','academic_level_code'),
      ('course','organization_id'),
      ('course','import_batch_id'),
      ('course','source_identifier'),
      ('course','source_record_locator'),
      ('course','source_version_label'),
      ('course','effective_from'),
      ('course','effective_to'),
      ('course','is_current'),
      ('course','created_at'),

      ('import_batch','import_batch_id'),
      ('import_batch','source_system_id'),
      ('import_batch','batch_identifier'),
      ('import_batch','loaded_at'),
      ('import_batch','source_fingerprint'),
      ('import_batch','authoritative_indicator'),
      ('import_batch','batch_status'),
      ('import_batch','notes'),
      ('import_batch','created_at'),

      ('source_system','source_system_id'),
      ('source_system','system_code'),
      ('source_system','system_name'),
      ('source_system','source_context'),
      ('source_system','description'),
      ('source_system','created_at')
)
SELECT e.table_name,
       e.column_name,
       CASE
           WHEN c.column_name IS NULL THEN 'MISSING'
           ELSE 'PRESENT'
       END AS status
FROM expected e
LEFT JOIN information_schema.columns c
  ON c.table_schema = 'core'
 AND c.table_name = e.table_name
 AND c.column_name = e.column_name
ORDER BY e.table_name, e.column_name;

-- 5. Constraint inventory.
SELECT n.nspname AS schema_name,
       c.relname AS table_name,
       con.conname AS constraint_name,
       CASE con.contype
         WHEN 'p' THEN 'PRIMARY KEY'
         WHEN 'f' THEN 'FOREIGN KEY'
         WHEN 'u' THEN 'UNIQUE'
         WHEN 'c' THEN 'CHECK'
         ELSE con.contype::text
       END AS constraint_type,
       pg_get_constraintdef(con.oid,true) AS constraint_definition
FROM pg_constraint con
JOIN pg_class c
  ON c.oid = con.conrelid
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE n.nspname = 'core'
  AND c.relname IN ('course','import_batch','source_system')
ORDER BY c.relname, constraint_type, con.conname;

-- 6. WW_CATALOG source-system identity.
SELECT source_system_id,
       system_code,
       system_name,
       source_context,
       description
FROM core.source_system
WHERE system_code = 'WW_CATALOG'
   OR source_system_id =
      'a5d205bc-fd64-4d07-b437-c4440425be42'::uuid
ORDER BY system_code, source_system_id;

-- 7. Current WW_CATALOG baseline.
SELECT count(*) AS current_ww_catalog_courses,
       count(DISTINCT c.course_id) AS distinct_course_id,
       count(DISTINCT c.source_identifier)
           AS distinct_university_course_id
FROM core.course c
JOIN core.import_batch ib
  ON ib.import_batch_id = c.import_batch_id
JOIN core.source_system ss
  ON ss.source_system_id = ib.source_system_id
WHERE ss.system_code = 'WW_CATALOG'
  AND c.is_current IS TRUE;

-- 8. Required projection-field null/blank failures.
SELECT
 count(*) FILTER (
     WHERE c.course_id IS NULL
 ) AS course_id_failures,

 count(*) FILTER (
     WHERE c.source_identifier IS NULL
        OR btrim(c.source_identifier) = ''
 ) AS university_course_id_failures,

 count(*) FILTER (
     WHERE c.course_code IS NULL
        OR btrim(c.course_code) = ''
 ) AS course_code_failures,

 count(*) FILTER (
     WHERE c.course_title IS NULL
        OR btrim(c.course_title) = ''
 ) AS course_title_failures,

 count(*) FILTER (
     WHERE c.import_batch_id IS NULL
 ) AS core_import_batch_id_failures,

 count(*) FILTER (
     WHERE c.source_record_locator IS NULL
        OR btrim(c.source_record_locator) = ''
 ) AS source_record_locator_failures,

 count(*) FILTER (
     WHERE c.source_version_label IS NULL
        OR btrim(c.source_version_label) = ''
 ) AS source_version_label_failures,

 count(*) FILTER (
   WHERE c.course_id IS NULL
      OR c.source_identifier IS NULL
      OR btrim(c.source_identifier) = ''
      OR c.course_code IS NULL
      OR btrim(c.course_code) = ''
      OR c.course_title IS NULL
      OR btrim(c.course_title) = ''
      OR c.import_batch_id IS NULL
      OR c.source_record_locator IS NULL
      OR btrim(c.source_record_locator) = ''
      OR c.source_version_label IS NULL
      OR btrim(c.source_version_label) = ''
      OR ss.system_code IS NULL
      OR btrim(ss.system_code) = ''
 ) AS rows_with_any_required_field_failure

FROM core.course c
JOIN core.import_batch ib
  ON ib.import_batch_id = c.import_batch_id
JOIN core.source_system ss
  ON ss.source_system_id = ib.source_system_id
WHERE ss.system_code = 'WW_CATALOG'
  AND c.is_current IS TRUE;

-- 9. Course UUID duplicates.
-- Expected: zero returned rows.
SELECT course_id,
       count(*) AS duplicate_count
FROM core.course
GROUP BY course_id
HAVING count(*) > 1
ORDER BY course_id;

-- 10. Source-identifier duplicates.
-- Expected: zero returned rows.
SELECT c.source_identifier AS university_course_id,
       count(*) AS duplicate_count
FROM core.course c
JOIN core.import_batch ib
  ON ib.import_batch_id = c.import_batch_id
JOIN core.source_system ss
  ON ss.source_system_id = ib.source_system_id
WHERE ss.system_code = 'WW_CATALOG'
  AND c.is_current IS TRUE
GROUP BY c.source_identifier
HAVING count(*) > 1
ORDER BY c.source_identifier;

-- 11. Informational Course Code duplicates.
-- Course Code is not treated as the durable Course identity.
SELECT c.course_code,
       count(*) AS course_count,
       string_agg(
           c.source_identifier,
           ', '
           ORDER BY c.source_identifier
       ) AS university_course_ids
FROM core.course c
JOIN core.import_batch ib
  ON ib.import_batch_id = c.import_batch_id
JOIN core.source_system ss
  ON ss.source_system_id = ib.source_system_id
WHERE ss.system_code = 'WW_CATALOG'
  AND c.is_current IS TRUE
GROUP BY c.course_code
HAVING count(*) > 1
ORDER BY c.course_code;

-- 12. Complete current-Course Import Batch lineage distribution.
SELECT c.import_batch_id,
       ib.batch_identifier,
       ib.batch_status,
       ib.source_fingerprint,
       count(*) AS current_course_rows
FROM core.course c
JOIN core.import_batch ib
  ON ib.import_batch_id = c.import_batch_id
JOIN core.source_system ss
  ON ss.source_system_id = ib.source_system_id
WHERE ss.system_code = 'WW_CATALOG'
  AND c.is_current IS TRUE
GROUP BY c.import_batch_id,
         ib.batch_identifier,
         ib.batch_status,
         ib.source_fingerprint
ORDER BY c.import_batch_id;

-- 13. Explicit 5 + 961 + 0 = 966 reconciliation.
SELECT
 count(*) FILTER (
   WHERE c.import_batch_id =
     '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
 ) AS second_batch_lineage,

 count(*) FILTER (
   WHERE c.import_batch_id =
     '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
 ) AS prior_batch_lineage,

 count(*) FILTER (
   WHERE c.import_batch_id NOT IN (
     '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,
     '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
   )
 ) AS other_batch_lineage,

 count(*) AS total_current_ww_catalog_courses

FROM core.course c
JOIN core.import_batch ib
  ON ib.import_batch_id = c.import_batch_id
JOIN core.source_system ss
  ON ss.source_system_id = ib.source_system_id
WHERE ss.system_code = 'WW_CATALOG'
  AND c.is_current IS TRUE;

-- 14. Gate 3 core Import Batch lifecycle evidence.
SELECT ib.import_batch_id,
       ib.batch_identifier,
       ib.batch_status,
       ib.authoritative_indicator,
       ib.loaded_at,
       ib.source_fingerprint,
       ib.created_at,
       ss.source_system_id,
       ss.system_code
FROM core.import_batch ib
JOIN core.source_system ss
  ON ss.source_system_id = ib.source_system_id
WHERE ib.import_batch_id IN (
 '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,
 '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
)
ORDER BY ib.import_batch_id;

-- 15. Proposed Gate 4 candidate projection sample.
-- Reads validated core only.
-- Reporting refresh metadata does not exist yet.
WITH candidate AS (
 SELECT
        c.course_id,
        c.source_identifier AS university_course_id,
        c.course_code,
        c.course_title,
        ss.system_code AS source_system_code,
        c.import_batch_id AS core_import_batch_id,
        c.source_record_locator,
        c.source_version_label,

        md5(
          concat_ws(
            E'\x1f',
            coalesce(c.source_identifier,''),
            coalesce(c.course_code,''),
            coalesce(c.course_title,''),
            coalesce(ss.system_code,''),
            coalesce(c.import_batch_id::text,''),
            coalesce(c.source_record_locator,''),
            coalesce(c.source_version_label,'')
          )
        ) AS business_row_hash

 FROM core.course c
 JOIN core.import_batch ib
   ON ib.import_batch_id = c.import_batch_id
 JOIN core.source_system ss
   ON ss.source_system_id = ib.source_system_id
 WHERE ss.system_code = 'WW_CATALOG'
   AND c.is_current IS TRUE
)
SELECT *
FROM candidate
ORDER BY course_code COLLATE "C",
         university_course_id COLLATE "C",
         course_id
LIMIT 25;

-- 16. Candidate count and deterministic ordered checksum.
WITH candidate AS (
 SELECT
        c.course_id,
        c.source_identifier AS university_course_id,
        c.course_code,

        md5(
          concat_ws(
            E'\x1f',
            coalesce(c.source_identifier,''),
            coalesce(c.course_code,''),
            coalesce(c.course_title,''),
            coalesce(ss.system_code,''),
            coalesce(c.import_batch_id::text,''),
            coalesce(c.source_record_locator,''),
            coalesce(c.source_version_label,'')
          )
        ) AS business_row_hash

 FROM core.course c
 JOIN core.import_batch ib
   ON ib.import_batch_id = c.import_batch_id
 JOIN core.source_system ss
   ON ss.source_system_id = ib.source_system_id
 WHERE ss.system_code = 'WW_CATALOG'
   AND c.is_current IS TRUE
)
SELECT
       count(*) AS candidate_count,
       count(DISTINCT course_id)
           AS distinct_candidate_course_id,

       md5(
         string_agg(
           business_row_hash,
           ''
           ORDER BY
             course_code COLLATE "C",
             university_course_id COLLATE "C",
             course_id
         )
       ) AS deterministic_candidate_business_checksum

FROM candidate;

-- 17. Final Gate 4.1 PASS/FAIL summary.
WITH candidate AS (
 SELECT
        c.course_id,
        c.source_identifier AS university_course_id,
        c.course_code,
        c.course_title,
        ss.system_code AS source_system_code,
        c.import_batch_id AS core_import_batch_id,
        c.source_record_locator,
        c.source_version_label,

        md5(
          concat_ws(
            E'\x1f',
            coalesce(c.source_identifier,''),
            coalesce(c.course_code,''),
            coalesce(c.course_title,''),
            coalesce(ss.system_code,''),
            coalesce(c.import_batch_id::text,''),
            coalesce(c.source_record_locator,''),
            coalesce(c.source_version_label,'')
          )
        ) AS business_row_hash

 FROM core.course c
 JOIN core.import_batch ib
   ON ib.import_batch_id = c.import_batch_id
 JOIN core.source_system ss
   ON ss.source_system_id = ib.source_system_id
 WHERE ss.system_code = 'WW_CATALOG'
   AND c.is_current IS TRUE
),

metrics AS (
 SELECT
        count(*) AS total_rows,

        count(DISTINCT course_id)
            AS distinct_ids,

        count(*) FILTER (
          WHERE university_course_id IS NULL
             OR btrim(university_course_id) = ''
             OR course_code IS NULL
             OR btrim(course_code) = ''
             OR course_title IS NULL
             OR btrim(course_title) = ''
             OR core_import_batch_id IS NULL
             OR source_record_locator IS NULL
             OR btrim(source_record_locator) = ''
             OR source_version_label IS NULL
             OR btrim(source_version_label) = ''
        ) AS required_failures,

        count(*) FILTER (
          WHERE core_import_batch_id =
            '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
        ) AS second_rows,

        count(*) FILTER (
          WHERE core_import_batch_id =
            '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
        ) AS prior_rows,

        count(*) FILTER (
          WHERE core_import_batch_id NOT IN (
           '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,
           '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
          )
        ) AS other_rows,

        md5(
          string_agg(
            business_row_hash,
            ''
            ORDER BY
              course_code COLLATE "C",
              university_course_id COLLATE "C",
              course_id
          )
        ) AS checksum

 FROM candidate
),

duplicate_ids AS (
 SELECT count(*) AS duplicate_groups
 FROM (
   SELECT university_course_id
   FROM candidate
   GROUP BY university_course_id
   HAVING count(*) > 1
 ) d
),

lifecycle AS (
 SELECT
        count(*) FILTER (
          WHERE import_batch_id =
            '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
            AND upper(batch_status) = 'PROMOTED'
        ) AS second_promoted,

        count(*) FILTER (
          WHERE import_batch_id =
            '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
            AND upper(batch_status) = 'PROMOTED'
        ) AS prior_promoted

 FROM core.import_batch
),

checks AS (

 SELECT
        10 AS sequence,
        'transaction_read_only'::text AS metric,
        'on'::text AS expected,
        current_setting('transaction_read_only') AS actual,
        current_setting('transaction_read_only') = 'on' AS passed

 UNION ALL

 SELECT
        20,
        'ww_catalog_identity',
        '1',
        count(*)::text,
        count(*) = 1
 FROM core.source_system
 WHERE system_code = 'WW_CATALOG'
   AND source_system_id =
       'a5d205bc-fd64-4d07-b437-c4440425be42'::uuid

 UNION ALL

 SELECT
        30,
        'current_ww_catalog_courses',
        '966',
        total_rows::text,
        total_rows = 966
 FROM metrics

 UNION ALL

 SELECT
        40,
        'distinct_course_id',
        '966',
        distinct_ids::text,
        distinct_ids = 966
 FROM metrics

 UNION ALL

 SELECT
        50,
        'required_field_failures',
        '0',
        required_failures::text,
        required_failures = 0
 FROM metrics

 UNION ALL

 SELECT
        60,
        'duplicate_source_id_groups',
        '0',
        duplicate_groups::text,
        duplicate_groups = 0
 FROM duplicate_ids

 UNION ALL

 SELECT
        70,
        'second_batch_lineage',
        '5',
        second_rows::text,
        second_rows = 5
 FROM metrics

 UNION ALL

 SELECT
        80,
        'prior_batch_lineage',
        '961',
        prior_rows::text,
        prior_rows = 961
 FROM metrics

 UNION ALL

 SELECT
        90,
        'other_batch_lineage',
        '0',
        other_rows::text,
        other_rows = 0
 FROM metrics

 UNION ALL

 SELECT
        100,
        'second_batch_core_status_promoted',
        '1',
        second_promoted::text,
        second_promoted = 1
 FROM lifecycle

 UNION ALL

 SELECT
        110,
        'prior_batch_core_status_promoted',
        '1',
        prior_promoted::text,
        prior_promoted = 1
 FROM lifecycle

 UNION ALL

 SELECT
        120,
        'candidate_count',
        '966',
        total_rows::text,
        total_rows = 966
 FROM metrics

 UNION ALL

 SELECT
        130,
        'candidate_checksum',
        'present',
        coalesce(checksum,'<NULL>'),
        checksum IS NOT NULL
 FROM metrics
)

SELECT
       sequence,
       metric,
       expected,
       actual,
       CASE
           WHEN passed THEN 'PASS'
           ELSE 'FAIL'
       END AS status
FROM checks

UNION ALL

SELECT
       999,
       'GATE_4_1_PREFLIGHT',
       'PASS',
       CASE
           WHEN bool_and(passed) THEN 'PASS'
           ELSE 'FAIL'
       END,
       CASE
           WHEN bool_and(passed) THEN 'PASS'
           ELSE 'FAIL'
       END
FROM checks

ORDER BY sequence;

ROLLBACK;