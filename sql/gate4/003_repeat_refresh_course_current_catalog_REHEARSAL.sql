-- Directus Relational Repository
-- Gate 4.5: Idempotency and Repeatability Validation
-- AUTHORITATIVE COMMIT-VERSION DRAFT
--
-- Proposed path:
-- C:\Directus\relational-repository\sql\gate4\
-- 003_repeat_refresh_course_current_catalog.sql
--
-- DO NOT EXECUTE YET.
--
-- Gate 4.1 SHA-256:
-- CADC8B20258EF21F6D90B0069FB0D087B1301D85A8F4D7124C3A3C66F653AE46
--
-- Gate 4.2 SHA-256:
-- 3792F3BD5C19CD81A7E50620A266CCF2751CCD2FCAA60E5DB4FFDC242C6188D8
--
-- Gate 4.3 SHA-256:
-- A6689281A43D34A38B302568AFD071774122ADEBB404E6D8563852B510E86A7B
--
-- Gate 4.4 accepted first refresh run:
-- 3a485fbc-4a66-4118-a475-2a33f2003a7b
--
-- Frozen checksum:
-- 666d67d56d4c492ea0cdd7a63a7f85fd
--
-- Unchanged-source target:
-- source=966; inserted=0; updated=0; deleted=0; unchanged=966
-- projection=966; distinct course_id=966
-- total/completed refresh runs after refresh=2/2

\set ON_ERROR_STOP on

BEGIN;

-- ===========================================================================
-- 1. FROZEN GATE 4.4 ENTRY VALIDATION
-- ===========================================================================

DO $entry$
DECLARE
    v_schema_count       bigint;
    v_table_count        bigint;
    v_projection_rows    bigint;
    v_distinct_ids       bigint;
    v_distinct_runs      bigint;
    v_distinct_asof      bigint;
    v_rows_for_prior     bigint;
    v_projection_hash    text;
    v_total_runs         bigint;
    v_completed_runs     bigint;
    v_prior_runs         bigint;
    v_prior_source       bigint;
    v_prior_inserted     bigint;
    v_prior_updated      bigint;
    v_prior_deleted      bigint;
    v_prior_unchanged    bigint;
    v_prior_hash         text;
    v_prior_null_error   bigint;
    v_source_count       bigint;
    v_second_promoted    bigint;
    v_prior_promoted     bigint;
BEGIN
    SELECT count(*)
    INTO v_schema_count
    FROM pg_namespace
    WHERE nspname = 'reporting';

    SELECT count(*)
    INTO v_table_count
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'reporting'
      AND c.relkind IN ('r','p')
      AND c.relname IN
          ('projection_refresh_run','course_current_catalog');

    IF v_schema_count <> 1 OR v_table_count <> 2 THEN
        RAISE EXCEPTION
            'Gate 4.5 structure failure: schema %, authorized tables %.',
            v_schema_count, v_table_count;
    END IF;

    SELECT
        count(*),
        count(DISTINCT course_id),
        count(DISTINCT report_refresh_run_id),
        count(DISTINCT report_as_of_utc),
        count(*) FILTER
        (
            WHERE report_refresh_run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
        ),
        md5
        (
            string_agg
            (
                business_row_hash,
                ''
                ORDER BY
                    course_code COLLATE "C",
                    university_course_id COLLATE "C",
                    course_id
            )
        )
    INTO
        v_projection_rows,
        v_distinct_ids,
        v_distinct_runs,
        v_distinct_asof,
        v_rows_for_prior,
        v_projection_hash
    FROM reporting.course_current_catalog;

    IF v_projection_rows <> 966
       OR v_distinct_ids <> 966
       OR v_distinct_runs <> 1
       OR v_distinct_asof <> 1
       OR v_rows_for_prior <> 966
       OR v_projection_hash IS DISTINCT FROM
          '666d67d56d4c492ea0cdd7a63a7f85fd'
    THEN
        RAISE EXCEPTION
            'Gate 4.5 projection baseline failure: rows %, IDs %, runs %, as-of %, prior rows %, checksum %.',
            v_projection_rows, v_distinct_ids, v_distinct_runs,
            v_distinct_asof, v_rows_for_prior,
            coalesce(v_projection_hash,'<NULL>');
    END IF;

    SELECT
        count(*),
        count(*) FILTER (WHERE status = 'COMPLETED'),
        count(*) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
        ),
        max(source_row_count) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
        ),
        max(rows_inserted) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
        ),
        max(rows_updated) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
        ),
        max(rows_deleted) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
        ),
        max(rows_unchanged) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
        ),
        max(business_checksum) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
        ),
        count(*) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
              AND error_information IS NULL
        )
    INTO
        v_total_runs,
        v_completed_runs,
        v_prior_runs,
        v_prior_source,
        v_prior_inserted,
        v_prior_updated,
        v_prior_deleted,
        v_prior_unchanged,
        v_prior_hash,
        v_prior_null_error
    FROM reporting.projection_refresh_run;

    IF v_total_runs <> 1
       OR v_completed_runs <> 1
       OR v_prior_runs <> 1
       OR v_prior_source <> 966
       OR v_prior_inserted <> 966
       OR v_prior_updated <> 0
       OR v_prior_deleted <> 0
       OR v_prior_unchanged <> 0
       OR v_prior_hash IS DISTINCT FROM
          '666d67d56d4c492ea0cdd7a63a7f85fd'
       OR v_prior_null_error <> 1
    THEN
        RAISE EXCEPTION
            'Gate 4.5 prior-run baseline failure.';
    END IF;

    SELECT count(*)
    INTO v_source_count
    FROM core.source_system
    WHERE source_system_id =
          'a5d205bc-fd64-4d07-b437-c4440425be42'::uuid
      AND system_code = 'WW_CATALOG';

    SELECT
        count(*) FILTER
        (
            WHERE import_batch_id =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
              AND upper(batch_status) = 'PROMOTED'
        ),
        count(*) FILTER
        (
            WHERE import_batch_id =
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
              AND upper(batch_status) = 'PROMOTED'
        )
    INTO v_second_promoted, v_prior_promoted
    FROM core.import_batch;

    IF v_source_count <> 1
       OR v_second_promoted <> 1
       OR v_prior_promoted <> 1
    THEN
        RAISE EXCEPTION
            'Gate 4.5 source/batch lifecycle failure.';
    END IF;
END
$entry$;

-- ===========================================================================
-- 2. TRANSACTION-SCOPED CONTEXT AND PRE-REFRESH BASELINE
-- ===========================================================================

CREATE TEMP TABLE gate4_5_refresh_context
(
    run_id              uuid        NOT NULL,
    report_as_of_utc    timestamptz NOT NULL,
    source_row_count    bigint,
    candidate_checksum  text,
    rows_inserted       bigint,
    rows_updated        bigint,
    rows_deleted        bigint,
    rows_unchanged      bigint
)
ON COMMIT DROP;

CREATE TEMP TABLE gate4_5_projection_baseline
ON COMMIT DROP
AS
SELECT
    course_id,
    university_course_id,
    course_code,
    course_title,
    source_system_code,
    core_import_batch_id,
    source_record_locator,
    source_version_label,
    business_row_hash
FROM reporting.course_current_catalog;

-- ===========================================================================
-- 3. REGISTER NEW STARTED REFRESH RUN
-- ===========================================================================

WITH new_run AS
(
    INSERT INTO reporting.projection_refresh_run
    (
        projection_name,
        source_filter,
        source_state,
        status,
        notes
    )
    VALUES
    (
        'course_current_catalog',
        jsonb_build_object
        (
            'source_system_code','WW_CATALOG',
            'is_current',true
        ),
        jsonb_build_object
        (
            'gate_4_1_sql_sha256',
            'CADC8B20258EF21F6D90B0069FB0D087B1301D85A8F4D7124C3A3C66F653AE46',
            'gate_4_2_sql_sha256',
            '3792F3BD5C19CD81A7E50620A266CCF2751CCD2FCAA60E5DB4FFDC242C6188D8',
            'gate_4_3_sql_sha256',
            'A6689281A43D34A38B302568AFD071774122ADEBB404E6D8563852B510E86A7B',
            'gate_4_4_accepted_run_id',
            '3a485fbc-4a66-4118-a475-2a33f2003a7b',
            'frozen_candidate_checksum',
            '666d67d56d4c492ea0cdd7a63a7f85fd',
            'expected_current_rows',966,
            'expected_distinct_course_ids',966
        ),
        'STARTED',
        'Gate 4.5 unchanged-source repeat refresh.'
    )
    RETURNING run_id, started_at
)
INSERT INTO gate4_5_refresh_context
(
    run_id,
    report_as_of_utc
)
SELECT run_id, started_at
FROM new_run;

-- ===========================================================================
-- 4. BUILD FROZEN CANDIDATE
-- ===========================================================================

CREATE TEMP TABLE gate4_5_candidate
ON COMMIT DROP
AS
SELECT
    c.course_id,
    c.source_identifier AS university_course_id,
    c.course_code,
    c.course_title,
    ss.system_code AS source_system_code,
    c.import_batch_id AS core_import_batch_id,
    c.source_record_locator,
    c.source_version_label,
    md5
    (
        concat_ws
        (
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
  AND c.is_current IS TRUE;

UPDATE gate4_5_refresh_context
SET
    source_row_count =
        (SELECT count(*) FROM gate4_5_candidate),
    candidate_checksum =
    (
        SELECT md5
        (
            string_agg
            (
                business_row_hash,
                ''
                ORDER BY
                    course_code COLLATE "C",
                    university_course_id COLLATE "C",
                    course_id
            )
        )
        FROM gate4_5_candidate
    );

-- ===========================================================================
-- 5. CANDIDATE AND PRE-DML IDEMPOTENCY ASSERTIONS
-- ===========================================================================

DO $candidate$
DECLARE
    v_rows              bigint;
    v_distinct_ids      bigint;
    v_required          bigint;
    v_duplicates        bigint;
    v_second            bigint;
    v_prior             bigint;
    v_other             bigint;
    v_checksum          text;
    v_missing_candidate bigint;
    v_missing_baseline  bigint;
    v_hash_mismatch     bigint;
BEGIN
    SELECT
        count(*),
        count(DISTINCT course_id),
        count(*) FILTER
        (
            WHERE course_id IS NULL
               OR university_course_id IS NULL
               OR btrim(university_course_id) = ''
               OR course_code IS NULL
               OR btrim(course_code) = ''
               OR course_title IS NULL
               OR btrim(course_title) = ''
               OR source_system_code <> 'WW_CATALOG'
               OR core_import_batch_id IS NULL
               OR source_record_locator IS NULL
               OR btrim(source_record_locator) = ''
               OR source_version_label IS NULL
               OR btrim(source_version_label) = ''
        )
    INTO v_rows, v_distinct_ids, v_required
    FROM gate4_5_candidate;

    SELECT count(*)
    INTO v_duplicates
    FROM
    (
        SELECT university_course_id
        FROM gate4_5_candidate
        GROUP BY university_course_id
        HAVING count(*) > 1
    ) d;

    SELECT
        count(*) FILTER
        (
            WHERE core_import_batch_id =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
        ),
        count(*) FILTER
        (
            WHERE core_import_batch_id =
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
        ),
        count(*) FILTER
        (
            WHERE core_import_batch_id NOT IN
            (
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
            )
        )
    INTO v_second, v_prior, v_other
    FROM gate4_5_candidate;

    SELECT candidate_checksum
    INTO v_checksum
    FROM gate4_5_refresh_context;

    SELECT count(*)
    INTO v_missing_candidate
    FROM gate4_5_candidate c
    LEFT JOIN gate4_5_projection_baseline b
      ON b.course_id = c.course_id
    WHERE b.course_id IS NULL;

    SELECT count(*)
    INTO v_missing_baseline
    FROM gate4_5_projection_baseline b
    LEFT JOIN gate4_5_candidate c
      ON c.course_id = b.course_id
    WHERE c.course_id IS NULL;

    SELECT count(*)
    INTO v_hash_mismatch
    FROM gate4_5_candidate c
    JOIN gate4_5_projection_baseline b
      ON b.course_id = c.course_id
    WHERE b.business_row_hash IS DISTINCT FROM c.business_row_hash;

    IF v_rows <> 966
       OR v_distinct_ids <> 966
       OR v_required <> 0
       OR v_duplicates <> 0
       OR v_second <> 5
       OR v_prior <> 961
       OR v_other <> 0
       OR v_checksum IS DISTINCT FROM
          '666d67d56d4c492ea0cdd7a63a7f85fd'
       OR v_missing_candidate <> 0
       OR v_missing_baseline <> 0
       OR v_hash_mismatch <> 0
    THEN
        RAISE EXCEPTION
            'Gate 4.5 candidate/baseline reconciliation failure.';
    END IF;
END
$candidate$;

UPDATE gate4_5_refresh_context
SET
    rows_inserted =
    (
        SELECT count(*)
        FROM gate4_5_candidate c
        LEFT JOIN reporting.course_current_catalog p
          ON p.course_id = c.course_id
        WHERE p.course_id IS NULL
    ),
    rows_updated =
    (
        SELECT count(*)
        FROM gate4_5_candidate c
        JOIN reporting.course_current_catalog p
          ON p.course_id = c.course_id
        WHERE p.business_row_hash IS DISTINCT FROM c.business_row_hash
    ),
    rows_deleted =
    (
        SELECT count(*)
        FROM reporting.course_current_catalog p
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM gate4_5_candidate c
            WHERE c.course_id = p.course_id
        )
    ),
    rows_unchanged =
    (
        SELECT count(*)
        FROM gate4_5_candidate c
        JOIN reporting.course_current_catalog p
          ON p.course_id = c.course_id
        WHERE p.business_row_hash IS NOT DISTINCT FROM c.business_row_hash
    );

DO $delta$
DECLARE
    v_i bigint;
    v_u bigint;
    v_d bigint;
    v_n bigint;
BEGIN
    SELECT
        rows_inserted,
        rows_updated,
        rows_deleted,
        rows_unchanged
    INTO v_i, v_u, v_d, v_n
    FROM gate4_5_refresh_context;

    IF v_i <> 0 OR v_u <> 0 OR v_d <> 0 OR v_n <> 966 THEN
        RAISE EXCEPTION
            'Gate 4.5 delta failure: expected 0/0/0/966; found %/%/%/%.',
            v_i, v_u, v_d, v_n;
    END IF;
END
$delta$;

-- ===========================================================================
-- 6. RECONCILE PROJECTION AND RETAG THE SNAPSHOT
-- ===========================================================================

DELETE FROM reporting.course_current_catalog p
WHERE NOT EXISTS
(
    SELECT 1
    FROM gate4_5_candidate c
    WHERE c.course_id = p.course_id
);

INSERT INTO reporting.course_current_catalog
(
    course_id,
    university_course_id,
    course_code,
    course_title,
    source_system_code,
    core_import_batch_id,
    source_record_locator,
    source_version_label,
    report_refresh_run_id,
    report_as_of_utc,
    business_row_hash
)
SELECT
    c.course_id,
    c.university_course_id,
    c.course_code,
    c.course_title,
    c.source_system_code,
    c.core_import_batch_id,
    c.source_record_locator,
    c.source_version_label,
    x.run_id,
    x.report_as_of_utc,
    c.business_row_hash
FROM gate4_5_candidate c
CROSS JOIN gate4_5_refresh_context x
ON CONFLICT (course_id)
DO UPDATE SET
    university_course_id  = EXCLUDED.university_course_id,
    course_code           = EXCLUDED.course_code,
    course_title          = EXCLUDED.course_title,
    source_system_code    = EXCLUDED.source_system_code,
    core_import_batch_id  = EXCLUDED.core_import_batch_id,
    source_record_locator = EXCLUDED.source_record_locator,
    source_version_label  = EXCLUDED.source_version_label,
    report_refresh_run_id = EXCLUDED.report_refresh_run_id,
    report_as_of_utc      = EXCLUDED.report_as_of_utc,
    business_row_hash     = EXCLUDED.business_row_hash;

UPDATE reporting.projection_refresh_run r
SET
    completed_at      = clock_timestamp(),
    source_row_count  = x.source_row_count,
    rows_inserted     = x.rows_inserted,
    rows_updated      = x.rows_updated,
    rows_deleted      = x.rows_deleted,
    rows_unchanged    = x.rows_unchanged,
    business_checksum = x.candidate_checksum,
    status            = 'COMPLETED',
    error_information = NULL
FROM gate4_5_refresh_context x
WHERE r.run_id = x.run_id;

-- ===========================================================================
-- 7. COMPLETE POST-REFRESH VALIDATION
-- ===========================================================================

DO $post$
DECLARE
    v_run                   uuid;
    v_asof                  timestamptz;
    v_projection_rows       bigint;
    v_distinct_ids          bigint;
    v_wrong_run             bigint;
    v_wrong_asof            bigint;
    v_candidate_missing     bigint;
    v_projection_missing    bigint;
    v_hash_mismatch         bigint;
    v_business_mismatch     bigint;
    v_projection_hash       text;
    v_total_runs            bigint;
    v_completed_runs        bigint;
    v_new_run               bigint;
    v_prior_run             bigint;
    v_prior_intact          bigint;
    v_i                     bigint;
    v_u                     bigint;
    v_d                     bigint;
    v_n                     bigint;
    v_refresh_hash          text;
    v_core_rows             bigint;
    v_core_distinct         bigint;
    v_required              bigint;
    v_duplicates            bigint;
    v_second                bigint;
    v_prior                 bigint;
    v_other                 bigint;
    v_second_promoted       bigint;
    v_prior_promoted        bigint;
    v_unauthorized          bigint;
    v_routines              bigint;
    v_triggers              bigint;
    v_policies              bigint;
    v_indexes               bigint;
BEGIN
    SELECT run_id, report_as_of_utc
    INTO v_run, v_asof
    FROM gate4_5_refresh_context;

    SELECT
        count(*),
        count(DISTINCT course_id),
        count(*) FILTER
        (
            WHERE report_refresh_run_id IS DISTINCT FROM v_run
        ),
        count(*) FILTER
        (
            WHERE report_as_of_utc IS DISTINCT FROM v_asof
        ),
        md5
        (
            string_agg
            (
                business_row_hash,
                ''
                ORDER BY
                    course_code COLLATE "C",
                    university_course_id COLLATE "C",
                    course_id
            )
        )
    INTO
        v_projection_rows,
        v_distinct_ids,
        v_wrong_run,
        v_wrong_asof,
        v_projection_hash
    FROM reporting.course_current_catalog;

    SELECT count(*)
    INTO v_candidate_missing
    FROM gate4_5_candidate c
    LEFT JOIN reporting.course_current_catalog p
      ON p.course_id = c.course_id
    WHERE p.course_id IS NULL;

    SELECT count(*)
    INTO v_projection_missing
    FROM reporting.course_current_catalog p
    LEFT JOIN gate4_5_candidate c
      ON c.course_id = p.course_id
    WHERE c.course_id IS NULL;

    SELECT count(*)
    INTO v_hash_mismatch
    FROM gate4_5_candidate c
    JOIN reporting.course_current_catalog p
      ON p.course_id = c.course_id
    WHERE p.business_row_hash IS DISTINCT FROM c.business_row_hash;

    SELECT count(*)
    INTO v_business_mismatch
    FROM gate4_5_projection_baseline b
    JOIN reporting.course_current_catalog p
      ON p.course_id = b.course_id
    WHERE p.university_course_id IS DISTINCT FROM b.university_course_id
       OR p.course_code IS DISTINCT FROM b.course_code
       OR p.course_title IS DISTINCT FROM b.course_title
       OR p.source_system_code IS DISTINCT FROM b.source_system_code
       OR p.core_import_batch_id IS DISTINCT FROM b.core_import_batch_id
       OR p.source_record_locator IS DISTINCT FROM b.source_record_locator
       OR p.source_version_label IS DISTINCT FROM b.source_version_label
       OR p.business_row_hash IS DISTINCT FROM b.business_row_hash;

    SELECT
        count(*),
        count(*) FILTER (WHERE status = 'COMPLETED'),
        count(*) FILTER (WHERE run_id = v_run),
        count(*) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
        ),
        count(*) FILTER
        (
            WHERE run_id =
              '3a485fbc-4a66-4118-a475-2a33f2003a7b'::uuid
              AND status = 'COMPLETED'
              AND source_row_count = 966
              AND rows_inserted = 966
              AND rows_updated = 0
              AND rows_deleted = 0
              AND rows_unchanged = 0
              AND business_checksum =
                  '666d67d56d4c492ea0cdd7a63a7f85fd'
              AND error_information IS NULL
        ),
        max(rows_inserted) FILTER (WHERE run_id = v_run),
        max(rows_updated) FILTER (WHERE run_id = v_run),
        max(rows_deleted) FILTER (WHERE run_id = v_run),
        max(rows_unchanged) FILTER (WHERE run_id = v_run),
        max(business_checksum) FILTER (WHERE run_id = v_run)
    INTO
        v_total_runs,
        v_completed_runs,
        v_new_run,
        v_prior_run,
        v_prior_intact,
        v_i,
        v_u,
        v_d,
        v_n,
        v_refresh_hash
    FROM reporting.projection_refresh_run;

    SELECT
        count(*),
        count(DISTINCT c.course_id),
        count(*) FILTER
        (
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
        ),
        count(*) FILTER
        (
            WHERE c.import_batch_id =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
        ),
        count(*) FILTER
        (
            WHERE c.import_batch_id =
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
        ),
        count(*) FILTER
        (
            WHERE c.import_batch_id NOT IN
            (
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
            )
        )
    INTO
        v_core_rows,
        v_core_distinct,
        v_required,
        v_second,
        v_prior,
        v_other
    FROM core.course c
    JOIN core.import_batch ib
      ON ib.import_batch_id = c.import_batch_id
    JOIN core.source_system ss
      ON ss.source_system_id = ib.source_system_id
    WHERE ss.system_code = 'WW_CATALOG'
      AND c.is_current IS TRUE;

    SELECT count(*)
    INTO v_duplicates
    FROM
    (
        SELECT c.source_identifier
        FROM core.course c
        JOIN core.import_batch ib
          ON ib.import_batch_id = c.import_batch_id
        JOIN core.source_system ss
          ON ss.source_system_id = ib.source_system_id
        WHERE ss.system_code = 'WW_CATALOG'
          AND c.is_current IS TRUE
        GROUP BY c.source_identifier
        HAVING count(*) > 1
    ) d;

    SELECT
        count(*) FILTER
        (
            WHERE import_batch_id =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
              AND upper(batch_status) = 'PROMOTED'
        ),
        count(*) FILTER
        (
            WHERE import_batch_id =
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
              AND upper(batch_status) = 'PROMOTED'
        )
    INTO v_second_promoted, v_prior_promoted
    FROM core.import_batch;

    SELECT count(*)
    INTO v_unauthorized
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'reporting'
      AND c.relkind IN ('r','p','v','m','S','f')
      AND c.relname NOT IN
          ('projection_refresh_run','course_current_catalog');

    SELECT count(*)
    INTO v_routines
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'reporting';

    SELECT count(*)
    INTO v_triggers
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'reporting'
      AND t.tgisinternal IS FALSE;

    SELECT count(*)
    INTO v_policies
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'reporting';

    SELECT count(*)
    INTO v_indexes
    FROM pg_class i
    JOIN pg_namespace n ON n.oid = i.relnamespace
    WHERE n.nspname = 'reporting'
      AND i.relkind = 'i'
      AND NOT EXISTS
      (
          SELECT 1
          FROM pg_constraint con
          WHERE con.conindid = i.oid
            AND con.contype IN ('p','u')
      );

    IF v_projection_rows <> 966
       OR v_distinct_ids <> 966
       OR v_wrong_run <> 0
       OR v_wrong_asof <> 0
       OR v_candidate_missing <> 0
       OR v_projection_missing <> 0
       OR v_hash_mismatch <> 0
       OR v_business_mismatch <> 0
       OR v_projection_hash IS DISTINCT FROM
          '666d67d56d4c492ea0cdd7a63a7f85fd'
       OR v_total_runs <> 2
       OR v_completed_runs <> 2
       OR v_new_run <> 1
       OR v_prior_run <> 1
       OR v_prior_intact <> 1
       OR v_i <> 0
       OR v_u <> 0
       OR v_d <> 0
       OR v_n <> 966
       OR v_refresh_hash IS DISTINCT FROM
          '666d67d56d4c492ea0cdd7a63a7f85fd'
       OR v_core_rows <> 966
       OR v_core_distinct <> 966
       OR v_required <> 0
       OR v_duplicates <> 0
       OR v_second <> 5
       OR v_prior <> 961
       OR v_other <> 0
       OR v_second_promoted <> 1
       OR v_prior_promoted <> 1
       OR v_unauthorized <> 0
       OR v_routines <> 0
       OR v_triggers <> 0
       OR v_policies <> 0
       OR v_indexes <> 0
    THEN
        RAISE EXCEPTION
            'Gate 4.5 post-refresh validation failure.';
    END IF;

    RAISE NOTICE
        'Gate 4.5 validation PASS: projection %, distinct IDs %, runs/completed %/%, inserted %, updated %, deleted %, unchanged %, checksum %.',
        v_projection_rows, v_distinct_ids,
        v_total_runs, v_completed_runs,
        v_i, v_u, v_d, v_n, v_projection_hash;
END
$post$;

-- ===========================================================================
-- 8. REVIEWABLE EVIDENCE
-- ===========================================================================

SELECT
    run_id,
    projection_name,
    started_at,
    completed_at,
    source_row_count,
    rows_inserted,
    rows_updated,
    rows_deleted,
    rows_unchanged,
    business_checksum,
    status,
    source_state,
    error_information
FROM reporting.projection_refresh_run
ORDER BY started_at, run_id;

SELECT
    count(*) AS projection_rows,
    count(DISTINCT course_id) AS distinct_course_ids,
    count(DISTINCT report_refresh_run_id) AS distinct_refresh_run_ids,
    count(DISTINCT report_as_of_utc) AS distinct_report_as_of_values,
    md5
    (
        string_agg
        (
            business_row_hash,
            ''
            ORDER BY
                course_code COLLATE "C",
                university_course_id COLLATE "C",
                course_id
        )
    ) AS projection_checksum
FROM reporting.course_current_catalog;

SELECT
    966::bigint AS expected_projection_rows,
    (SELECT count(*) FROM reporting.course_current_catalog)
        AS observed_projection_rows,
    966::bigint AS expected_distinct_course_ids,
    (SELECT count(DISTINCT course_id)
     FROM reporting.course_current_catalog)
        AS observed_distinct_course_ids,
    2::bigint AS expected_refresh_run_rows,
    (SELECT count(*) FROM reporting.projection_refresh_run)
        AS observed_refresh_run_rows,
    2::bigint AS expected_completed_runs,
    (SELECT count(*)
     FROM reporting.projection_refresh_run
     WHERE status = 'COMPLETED')
        AS observed_completed_runs,
    0::bigint AS expected_rows_inserted,
    x.rows_inserted AS observed_rows_inserted,
    0::bigint AS expected_rows_updated,
    x.rows_updated AS observed_rows_updated,
    0::bigint AS expected_rows_deleted,
    x.rows_deleted AS observed_rows_deleted,
    966::bigint AS expected_rows_unchanged,
    x.rows_unchanged AS observed_rows_unchanged,
    '666d67d56d4c492ea0cdd7a63a7f85fd'
        AS expected_projection_checksum,
    (
        SELECT md5
        (
            string_agg
            (
                business_row_hash,
                ''
                ORDER BY
                    course_code COLLATE "C",
                    university_course_id COLLATE "C",
                    course_id
            )
        )
        FROM reporting.course_current_catalog
    ) AS observed_projection_checksum,
    CASE
        WHEN x.rows_inserted = 0
         AND x.rows_updated = 0
         AND x.rows_deleted = 0
         AND x.rows_unchanged = 966
         AND (SELECT count(*)
              FROM reporting.course_current_catalog) = 966
         AND (SELECT count(*)
              FROM reporting.projection_refresh_run) = 2
         AND (SELECT count(*)
              FROM reporting.projection_refresh_run
              WHERE status = 'COMPLETED') = 2
         AND
         (
             SELECT md5
             (
                 string_agg
                 (
                     business_row_hash,
                     ''
                     ORDER BY
                         course_code COLLATE "C",
                         university_course_id COLLATE "C",
                         course_id
                 )
             )
             FROM reporting.course_current_catalog
         )
         IS NOT DISTINCT FROM
         '666d67d56d4c492ea0cdd7a63a7f85fd'
        THEN 'PASS'
        ELSE 'FAIL'
    END AS gate_4_5_recomputed_evidence_status
FROM gate4_5_refresh_context x;

-- ===========================================================================
-- 9. FINAL TRANSACTION ACTION
--
-- AUTHORITATIVE VERSION: COMMIT.
-- The later rehearsal copy must differ only by COMMIT -> ROLLBACK.
-- ===========================================================================
ROLLBACK;