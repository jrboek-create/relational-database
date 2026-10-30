-- Directus Relational Repository
-- Gate 4.3: Controlled Refresh and First Population
--
-- AUTHORITATIVE COMMIT-VERSION DRAFT
--
-- Target artifact:
-- C:\Directus\relational-repository\sql\gate4\002_refresh_course_current_catalog.sql
--
-- IMPORTANT:
--   DO NOT EXECUTE THIS FILE YET.
--
-- Required sequence:
--   1. Save complete artifact.
--   2. Capture metadata and SHA-256.
--   3. Run static validation.
--   4. Create separately fingerprinted ROLLBACK rehearsal copy.
--   5. Execute rehearsal.
--   6. Verify rollback restores Gate 4.2 empty state.
--   7. Obtain separate explicit COMMIT authorization.
--   8. Execute this authoritative COMMIT version.
--   9. Perform post-COMMIT reconciliation.
--
-- Gate 4.1 prerequisite:
--   PASS / COMPLETE
--
-- Gate 4.1 SQL SHA-256:
--   CADC8B20258EF21F6D90B0069FB0D087B1301D85A8F4D7124C3A3C66F653AE46
--
-- Frozen Gate 4.1 candidate checksum:
--   666d67d56d4c492ea0cdd7a63a7f85fd
--
-- Gate 4.2 prerequisite:
--   PASS / COMPLETE
--
-- Gate 4.2 SQL SHA-256:
--   3792F3BD5C19CD81A7E50620A266CCF2751CCD2FCAA60E5DB4FFDC242C6188D8
--
-- Frozen source baseline:
--   Current WW_CATALOG Courses:     966
--   Distinct course_id:             966
--   Required-field failures:        0
--   Duplicate source-ID groups:     0
--   Second-batch lineage:           5
--   Prior-batch lineage:            961
--   Other-batch lineage:            0
--
-- Source system:
--   WW_CATALOG
--   a5d205bc-fd64-4d07-b437-c4440425be42
--
-- Second batch:
--   53e0ae11-6a25-4f0a-9beb-814c8c3d1946
--
-- Prior batch:
--   06b1327c-95e0-49b7-b23c-103fb0fb3b20
--
-- Gate 4.3 is specifically the FIRST controlled population.
--
-- Required clean-entry state:
--   reporting.projection_refresh_run     = 0 rows
--   reporting.course_current_catalog     = 0 rows
--
-- Required first-population result:
--   reporting.projection_refresh_run     = 1 row
--   reporting.course_current_catalog     = 966 rows
--   rows_inserted                        = 966
--   rows_updated                         = 0
--   rows_deleted                         = 0
--   rows_unchanged                       = 0
--
-- Repeat-refresh/idempotency behavior belongs to Gate 4.5.
--
-- Authorized persistent DML targets only:
--   reporting.projection_refresh_run
--   reporting.course_current_catalog
--
-- This script does NOT:
--   * modify core.*;
--   * modify staging.*;
--   * read raw staging data;
--   * rerun Gate 3 promotion;
--   * create a second Course identity;
--   * create persistent helper objects;
--   * configure Directus;
--   * perform Gate 4.4+ work.
--
-- Temporary working tables are transaction-scoped and disappear at
-- COMMIT or ROLLBACK.

\set ON_ERROR_STOP on

BEGIN;


-- ===========================================================================
-- 1. GATE 4.3 CLEAN-ENTRY VALIDATION
-- ===========================================================================

DO $gate4_3_entry$

DECLARE

    v_reporting_schema_count      bigint;

    v_projection_table_count      bigint;

    v_refresh_table_count         bigint;

    v_existing_refresh_rows       bigint;

    v_existing_projection_rows    bigint;

    v_source_identity_count       bigint;

    v_second_promoted             bigint;

    v_prior_promoted              bigint;

BEGIN

    -- -----------------------------------------------------------------------
    -- reporting schema must already exist from Gate 4.2.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_reporting_schema_count

    FROM pg_namespace

    WHERE nspname = 'reporting';


    IF v_reporting_schema_count <> 1 THEN

        RAISE EXCEPTION
            'Gate 4.3 safety stop: expected exactly one reporting schema; found %.',
            v_reporting_schema_count;

    END IF;


    -- -----------------------------------------------------------------------
    -- Gate 4.2 projection table must exist.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_projection_table_count

    FROM pg_class c

    JOIN pg_namespace n
      ON n.oid = c.relnamespace

    WHERE n.nspname = 'reporting'

      AND c.relname = 'course_current_catalog'

      AND c.relkind IN
      (
          'r',
          'p'
      );


    IF v_projection_table_count <> 1 THEN

        RAISE EXCEPTION
            'Gate 4.3 safety stop: reporting.course_current_catalog is missing or invalid.';

    END IF;


    -- -----------------------------------------------------------------------
    -- Gate 4.2 refresh-run table must exist.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_refresh_table_count

    FROM pg_class c

    JOIN pg_namespace n
      ON n.oid = c.relnamespace

    WHERE n.nspname = 'reporting'

      AND c.relname = 'projection_refresh_run'

      AND c.relkind IN
      (
          'r',
          'p'
      );


    IF v_refresh_table_count <> 1 THEN

        RAISE EXCEPTION
            'Gate 4.3 safety stop: reporting.projection_refresh_run is missing or invalid.';

    END IF;


    -- -----------------------------------------------------------------------
    -- CLEAN-ENTRY ASSERTION
    --
    -- Gate 4.3 is the first controlled population.
    -- Both Gate 4.2 reporting tables must still be empty.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_existing_refresh_rows

    FROM reporting.projection_refresh_run;


    SELECT count(*)

    INTO v_existing_projection_rows

    FROM reporting.course_current_catalog;


    IF v_existing_refresh_rows <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.3 clean-entry failure: expected reporting.projection_refresh_run to contain 0 rows; found %.',
            v_existing_refresh_rows;

    END IF;


    IF v_existing_projection_rows <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.3 clean-entry failure: expected reporting.course_current_catalog to contain 0 rows; found %.',
            v_existing_projection_rows;

    END IF;


    -- -----------------------------------------------------------------------
    -- Frozen source-system identity.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_source_identity_count

    FROM core.source_system

    WHERE system_code = 'WW_CATALOG'

      AND source_system_id =
          'a5d205bc-fd64-4d07-b437-c4440425be42'::uuid;


    IF v_source_identity_count <> 1 THEN

        RAISE EXCEPTION
            'Gate 4.3 safety stop: WW_CATALOG source identity mismatch.';

    END IF;


    -- -----------------------------------------------------------------------
    -- Frozen import-batch lifecycle.
    -- -----------------------------------------------------------------------

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

    INTO

        v_second_promoted,

        v_prior_promoted

    FROM core.import_batch;


    IF v_second_promoted <> 1

       OR v_prior_promoted <> 1
    THEN

        RAISE EXCEPTION
            'Gate 4.3 clean-entry batch lifecycle failure: second %, prior %.',
            v_second_promoted,
            v_prior_promoted;

    END IF;

END

$gate4_3_entry$;


-- ===========================================================================
-- 2. TRANSACTION-SCOPED REFRESH CONTEXT
-- ===========================================================================

CREATE TEMP TABLE gate4_3_refresh_context
(
    run_id               uuid        NOT NULL,

    report_as_of_utc     timestamptz NOT NULL,

    source_row_count     bigint,

    candidate_checksum   text,

    rows_inserted        bigint,

    rows_updated         bigint,

    rows_deleted         bigint,

    rows_unchanged       bigint
)
ON COMMIT DROP;


-- ===========================================================================
-- 3. REGISTER STARTED REFRESH RUN
--
-- Final metrics intentionally remain NULL while status = STARTED.
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
            'source_system_code',
            'WW_CATALOG',

            'is_current',
            true
        ),

        jsonb_build_object
        (
            'gate_4_1_sql_sha256',
            'CADC8B20258EF21F6D90B0069FB0D087B1301D85A8F4D7124C3A3C66F653AE46',

            'gate_4_2_sql_sha256',
            '3792F3BD5C19CD81A7E50620A266CCF2751CCD2FCAA60E5DB4FFDC242C6188D8',

            'frozen_candidate_checksum',
            '666d67d56d4c492ea0cdd7a63a7f85fd',

            'expected_current_rows',
            966,

            'expected_distinct_course_ids',
            966,

            'second_batch_id',
            '53e0ae11-6a25-4f0a-9beb-814c8c3d1946',

            'prior_batch_id',
            '06b1327c-95e0-49b7-b23c-103fb0fb3b20'
        ),

        'STARTED',

        'Gate 4.3 first controlled population of the Current Worldwide Course Catalog.'
    )

    RETURNING
        run_id,
        started_at
)

INSERT INTO gate4_3_refresh_context
(
    run_id,
    report_as_of_utc
)

SELECT
    run_id,
    started_at

FROM new_run;


-- ===========================================================================
-- 4. BUILD TRANSACTION-SCOPED CANDIDATE
--
-- The business-row hash expression and deterministic ordering contract are
-- frozen from Gate 4.1.
-- ===========================================================================

CREATE TEMP TABLE gate4_3_candidate
ON COMMIT DROP
AS

SELECT

    c.course_id,

    c.source_identifier
        AS university_course_id,

    c.course_code,

    c.course_title,

    ss.system_code
        AS source_system_code,

    c.import_batch_id
        AS core_import_batch_id,

    c.source_record_locator,

    c.source_version_label,

    md5
    (
        concat_ws
        (
            E'\x1f',

            coalesce
            (
                c.source_identifier,
                ''
            ),

            coalesce
            (
                c.course_code,
                ''
            ),

            coalesce
            (
                c.course_title,
                ''
            ),

            coalesce
            (
                ss.system_code,
                ''
            ),

            coalesce
            (
                c.import_batch_id::text,
                ''
            ),

            coalesce
            (
                c.source_record_locator,
                ''
            ),

            coalesce
            (
                c.source_version_label,
                ''
            )
        )
    )
    AS business_row_hash

FROM core.course c

JOIN core.import_batch ib
  ON ib.import_batch_id = c.import_batch_id

JOIN core.source_system ss
  ON ss.source_system_id = ib.source_system_id

WHERE ss.system_code = 'WW_CATALOG'

  AND c.is_current IS TRUE;


-- ===========================================================================
-- 5. CAPTURE CANDIDATE COUNT AND CHECKSUM
-- ===========================================================================

UPDATE gate4_3_refresh_context ctx

SET

    source_row_count =
    (
        SELECT count(*)

        FROM gate4_3_candidate
    ),

    candidate_checksum =
    (
        SELECT

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

        FROM gate4_3_candidate
    );


-- ===========================================================================
-- 6. PRE-DML CANDIDATE ASSERTIONS
--
-- No reporting projection DML occurs until these assertions pass.
-- ===========================================================================

DO $gate4_3_candidate_validate$

DECLARE

    v_candidate_rows          bigint;

    v_distinct_course_ids     bigint;

    v_required_failures       bigint;

    v_duplicate_source_groups bigint;

    v_second_rows             bigint;

    v_prior_rows              bigint;

    v_other_rows              bigint;

    v_second_promoted         bigint;

    v_prior_promoted          bigint;

    v_candidate_checksum      text;

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

               OR source_system_code IS NULL

               OR source_system_code <> 'WW_CATALOG'

               OR core_import_batch_id IS NULL

               OR source_record_locator IS NULL

               OR btrim(source_record_locator) = ''

               OR source_version_label IS NULL

               OR btrim(source_version_label) = ''

               OR business_row_hash IS NULL

               OR btrim(business_row_hash) = ''
        )

    INTO

        v_candidate_rows,

        v_distinct_course_ids,

        v_required_failures

    FROM gate4_3_candidate;


    SELECT count(*)

    INTO v_duplicate_source_groups

    FROM
    (
        SELECT
            university_course_id

        FROM gate4_3_candidate

        GROUP BY
            university_course_id

        HAVING count(*) > 1

    ) duplicate_groups;


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

    INTO

        v_second_rows,

        v_prior_rows,

        v_other_rows

    FROM gate4_3_candidate;


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

    INTO

        v_second_promoted,

        v_prior_promoted

    FROM core.import_batch;


    SELECT candidate_checksum

    INTO v_candidate_checksum

    FROM gate4_3_refresh_context;


    IF v_candidate_rows <> 966 THEN

        RAISE EXCEPTION
            'Gate 4.3 candidate row-count failure: expected 966, found %.',
            v_candidate_rows;


    ELSIF v_distinct_course_ids <> 966 THEN

        RAISE EXCEPTION
            'Gate 4.3 candidate identity failure: expected 966 distinct course_id values, found %.',
            v_distinct_course_ids;


    ELSIF v_required_failures <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.3 candidate required-field failures: %.',
            v_required_failures;


    ELSIF v_duplicate_source_groups <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.3 duplicate University Course ID groups: %.',
            v_duplicate_source_groups;


    ELSIF v_second_rows <> 5

       OR v_prior_rows <> 961

       OR v_other_rows <> 0
    THEN

        RAISE EXCEPTION
            'Gate 4.3 candidate lineage failure: second %, prior %, other %.',
            v_second_rows,
            v_prior_rows,
            v_other_rows;


    ELSIF v_second_promoted <> 1

       OR v_prior_promoted <> 1
    THEN

        RAISE EXCEPTION
            'Gate 4.3 import-batch lifecycle failure: second %, prior %.',
            v_second_promoted,
            v_prior_promoted;


    ELSIF v_candidate_checksum IS DISTINCT FROM
          '666d67d56d4c492ea0cdd7a63a7f85fd'
    THEN

        RAISE EXCEPTION
            'Gate 4.3 candidate checksum failure: expected %, found %.',
            '666d67d56d4c492ea0cdd7a63a7f85fd',
            coalesce
            (
                v_candidate_checksum,
                '<NULL>'
            );

    END IF;

END

$gate4_3_candidate_validate$;


-- ===========================================================================
-- 7. CALCULATE BUSINESS-LEVEL REFRESH DELTAS
--
-- Gate 4.3 clean-entry assertions require both reporting tables to be empty.
-- Therefore the required first-population metrics are:
--
--   inserted  = 966
--   updated   = 0
--   deleted   = 0
--   unchanged = 0
--
-- The generalized calculations remain explicit so the evidence proves the
-- actual state rather than merely assigning expected constants.
-- ===========================================================================

UPDATE gate4_3_refresh_context ctx

SET

    rows_inserted =
    (
        SELECT count(*)

        FROM gate4_3_candidate candidate

        LEFT JOIN reporting.course_current_catalog existing
          ON existing.course_id = candidate.course_id

        WHERE existing.course_id IS NULL
    ),

    rows_updated =
    (
        SELECT count(*)

        FROM gate4_3_candidate candidate

        JOIN reporting.course_current_catalog existing
          ON existing.course_id = candidate.course_id

        WHERE existing.business_row_hash
              IS DISTINCT FROM
              candidate.business_row_hash
    ),

    rows_unchanged =
    (
        SELECT count(*)

        FROM gate4_3_candidate candidate

        JOIN reporting.course_current_catalog existing
          ON existing.course_id = candidate.course_id

        WHERE existing.business_row_hash
              IS NOT DISTINCT FROM
              candidate.business_row_hash
    ),

    rows_deleted =
    (
        SELECT count(*)

        FROM reporting.course_current_catalog existing

        WHERE NOT EXISTS
        (
            SELECT 1

            FROM gate4_3_candidate candidate

            WHERE candidate.course_id =
                  existing.course_id
        )
    );


-- ===========================================================================
-- 8. FIRST-POPULATION DELTA ASSERTION
--
-- This assertion occurs before projection DML.
-- ===========================================================================

DO $gate4_3_delta_validate$

DECLARE

    v_rows_inserted   bigint;

    v_rows_updated    bigint;

    v_rows_deleted    bigint;

    v_rows_unchanged  bigint;

BEGIN

    SELECT

        rows_inserted,

        rows_updated,

        rows_deleted,

        rows_unchanged

    INTO

        v_rows_inserted,

        v_rows_updated,

        v_rows_deleted,

        v_rows_unchanged

    FROM gate4_3_refresh_context;


    IF v_rows_inserted <> 966

       OR v_rows_updated <> 0

       OR v_rows_deleted <> 0

       OR v_rows_unchanged <> 0
    THEN

        RAISE EXCEPTION
            'Gate 4.3 first-population delta failure: expected inserted 966, updated 0, deleted 0, unchanged 0; found inserted %, updated %, deleted %, unchanged %.',
            v_rows_inserted,
            v_rows_updated,
            v_rows_deleted,
            v_rows_unchanged;

    END IF;

END

$gate4_3_delta_validate$;


-- ===========================================================================
-- 9. REMOVE ROWS NO LONGER IN THE APPROVED CANDIDATE
--
-- Under the Gate 4.3 clean-entry contract this must affect zero rows.
-- The statement remains part of the controlled reconciliation algorithm.
-- ===========================================================================

DELETE FROM reporting.course_current_catalog existing

WHERE NOT EXISTS
(
    SELECT 1

    FROM gate4_3_candidate candidate

    WHERE candidate.course_id =
          existing.course_id
);


-- ===========================================================================
-- 10. INSERT / RECONCILE CURRENT PROJECTION
--
-- Existing core.course.course_id is preserved as the reporting PK.
--
-- All retained rows receive the current refresh-run identity and one
-- consistent report_as_of_utc timestamp.
-- ===========================================================================

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

    candidate.course_id,

    candidate.university_course_id,

    candidate.course_code,

    candidate.course_title,

    candidate.source_system_code,

    candidate.core_import_batch_id,

    candidate.source_record_locator,

    candidate.source_version_label,

    ctx.run_id,

    ctx.report_as_of_utc,

    candidate.business_row_hash

FROM gate4_3_candidate candidate

CROSS JOIN gate4_3_refresh_context ctx

ON CONFLICT (course_id)

DO UPDATE

SET

    university_course_id =
        EXCLUDED.university_course_id,

    course_code =
        EXCLUDED.course_code,

    course_title =
        EXCLUDED.course_title,

    source_system_code =
        EXCLUDED.source_system_code,

    core_import_batch_id =
        EXCLUDED.core_import_batch_id,

    source_record_locator =
        EXCLUDED.source_record_locator,

    source_version_label =
        EXCLUDED.source_version_label,

    report_refresh_run_id =
        EXCLUDED.report_refresh_run_id,

    report_as_of_utc =
        EXCLUDED.report_as_of_utc,

    business_row_hash =
        EXCLUDED.business_row_hash;


-- ===========================================================================
-- 11. COMPLETE REFRESH RUN
-- ===========================================================================

UPDATE reporting.projection_refresh_run run

SET

    completed_at =
        clock_timestamp(),

    source_row_count =
        ctx.source_row_count,

    rows_inserted =
        ctx.rows_inserted,

    rows_updated =
        ctx.rows_updated,

    rows_deleted =
        ctx.rows_deleted,

    rows_unchanged =
        ctx.rows_unchanged,

    business_checksum =
        ctx.candidate_checksum,

    status =
        'COMPLETED',

    error_information =
        NULL

FROM gate4_3_refresh_context ctx

WHERE run.run_id = ctx.run_id;


-- ===========================================================================
-- 12. POST-REFRESH ASSERTIONS
-- ===========================================================================

DO $gate4_3_post_validate$

DECLARE

    v_run_id                    uuid;

    v_report_as_of_utc          timestamptz;

    v_candidate_checksum        text;

    v_projection_rows           bigint;

    v_projection_distinct_ids   bigint;

    v_candidate_missing         bigint;

    v_projection_missing        bigint;

    v_hash_mismatches           bigint;

    v_wrong_refresh_run         bigint;

    v_wrong_as_of               bigint;

    v_projection_checksum       text;

    v_refresh_run_count         bigint;

    v_total_refresh_run_count   bigint;

    v_completed_run_count       bigint;

    v_source_row_count          bigint;

    v_rows_inserted             bigint;

    v_rows_updated              bigint;

    v_rows_deleted              bigint;

    v_rows_unchanged            bigint;

    v_refresh_checksum          text;

    v_current_rows              bigint;

    v_distinct_course_ids       bigint;

    v_required_failures         bigint;

    v_duplicate_source_groups   bigint;

    v_second_rows               bigint;

    v_prior_rows                bigint;

    v_other_rows                bigint;

    v_second_promoted           bigint;

    v_prior_promoted            bigint;

    v_unauthorized_relations    bigint;

    v_reporting_routines        bigint;

    v_user_triggers             bigint;

    v_policies                  bigint;

    v_standalone_indexes        bigint;

BEGIN

    SELECT

        run_id,

        report_as_of_utc,

        candidate_checksum

    INTO

        v_run_id,

        v_report_as_of_utc,

        v_candidate_checksum

    FROM gate4_3_refresh_context;


    -- -----------------------------------------------------------------------
    -- Projection totals.
    -- -----------------------------------------------------------------------

    SELECT

        count(*),

        count(DISTINCT course_id)

    INTO

        v_projection_rows,

        v_projection_distinct_ids

    FROM reporting.course_current_catalog;


    -- -----------------------------------------------------------------------
    -- Candidate -> projection missing rows.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_candidate_missing

    FROM gate4_3_candidate candidate

    LEFT JOIN reporting.course_current_catalog projection
      ON projection.course_id = candidate.course_id

    WHERE projection.course_id IS NULL;


    -- -----------------------------------------------------------------------
    -- Projection -> candidate missing rows.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_projection_missing

    FROM reporting.course_current_catalog projection

    LEFT JOIN gate4_3_candidate candidate
      ON candidate.course_id = projection.course_id

    WHERE candidate.course_id IS NULL;


    -- -----------------------------------------------------------------------
    -- Business-hash mismatches.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_hash_mismatches

    FROM gate4_3_candidate candidate

    JOIN reporting.course_current_catalog projection
      ON projection.course_id = candidate.course_id

    WHERE projection.business_row_hash
          IS DISTINCT FROM
          candidate.business_row_hash;


    -- -----------------------------------------------------------------------
    -- Refresh-run identity.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_wrong_refresh_run

    FROM reporting.course_current_catalog

    WHERE report_refresh_run_id
          IS DISTINCT FROM
          v_run_id;


    -- -----------------------------------------------------------------------
    -- Consistent report-as-of timestamp.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_wrong_as_of

    FROM reporting.course_current_catalog

    WHERE report_as_of_utc
          IS DISTINCT FROM
          v_report_as_of_utc;


    -- -----------------------------------------------------------------------
    -- Projection checksum.
    -- -----------------------------------------------------------------------

    SELECT

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

    INTO v_projection_checksum

    FROM reporting.course_current_catalog;


    -- -----------------------------------------------------------------------
    -- Current refresh-run evidence.
    -- -----------------------------------------------------------------------

    SELECT

        count(*),

        count(*) FILTER
        (
            WHERE status = 'COMPLETED'
        ),

        max(source_row_count),

        max(rows_inserted),

        max(rows_updated),

        max(rows_deleted),

        max(rows_unchanged),

        max(business_checksum)

    INTO

        v_refresh_run_count,

        v_completed_run_count,

        v_source_row_count,

        v_rows_inserted,

        v_rows_updated,

        v_rows_deleted,

        v_rows_unchanged,

        v_refresh_checksum

    FROM reporting.projection_refresh_run

    WHERE run_id = v_run_id;


    -- -----------------------------------------------------------------------
    -- Gate 4.3 requires exactly one TOTAL refresh-run row after population.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_total_refresh_run_count

    FROM reporting.projection_refresh_run;


    -- -----------------------------------------------------------------------
    -- Recompute frozen core baseline after reporting DML.
    -- -----------------------------------------------------------------------

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

        v_current_rows,

        v_distinct_course_ids,

        v_required_failures,

        v_second_rows,

        v_prior_rows,

        v_other_rows

    FROM core.course c

    JOIN core.import_batch ib
      ON ib.import_batch_id = c.import_batch_id

    JOIN core.source_system ss
      ON ss.source_system_id = ib.source_system_id

    WHERE ss.system_code = 'WW_CATALOG'

      AND c.is_current IS TRUE;


    SELECT count(*)

    INTO v_duplicate_source_groups

    FROM
    (
        SELECT
            c.source_identifier

        FROM core.course c

        JOIN core.import_batch ib
          ON ib.import_batch_id = c.import_batch_id

        JOIN core.source_system ss
          ON ss.source_system_id = ib.source_system_id

        WHERE ss.system_code = 'WW_CATALOG'

          AND c.is_current IS TRUE

        GROUP BY
            c.source_identifier

        HAVING count(*) > 1

    ) duplicate_groups;


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

    INTO

        v_second_promoted,

        v_prior_promoted

    FROM core.import_batch;


    -- -----------------------------------------------------------------------
    -- Unauthorized persistent reporting relations.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_unauthorized_relations

    FROM pg_class c

    JOIN pg_namespace n
      ON n.oid = c.relnamespace

    WHERE n.nspname = 'reporting'

      AND c.relkind IN
      (
          'r',
          'p',
          'v',
          'm',
          'S',
          'f'
      )

      AND c.relname NOT IN
      (
          'projection_refresh_run',
          'course_current_catalog'
      );


    -- -----------------------------------------------------------------------
    -- Unauthorized persistent reporting routines.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_reporting_routines

    FROM pg_proc p

    JOIN pg_namespace n
      ON n.oid = p.pronamespace

    WHERE n.nspname = 'reporting';


    -- -----------------------------------------------------------------------
    -- Unauthorized non-internal triggers.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_user_triggers

    FROM pg_trigger trg

    JOIN pg_class cls
      ON cls.oid = trg.tgrelid

    JOIN pg_namespace n
      ON n.oid = cls.relnamespace

    WHERE n.nspname = 'reporting'

      AND trg.tgisinternal IS FALSE;


    -- -----------------------------------------------------------------------
    -- Unauthorized row-security policies.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_policies

    FROM pg_policy pol

    JOIN pg_class cls
      ON cls.oid = pol.polrelid

    JOIN pg_namespace n
      ON n.oid = cls.relnamespace

    WHERE n.nspname = 'reporting';


    -- -----------------------------------------------------------------------
    -- Unauthorized standalone indexes.
    --
    -- Constraint-backed PK/UNIQUE indexes are authorized.
    -- -----------------------------------------------------------------------

    SELECT count(*)

    INTO v_standalone_indexes

    FROM pg_class idx

    JOIN pg_namespace n
      ON n.oid = idx.relnamespace

    WHERE n.nspname = 'reporting'

      AND idx.relkind = 'i'

      AND NOT EXISTS
      (
          SELECT 1

          FROM pg_constraint con

          WHERE con.conindid = idx.oid

            AND con.contype IN
            (
                'p',
                'u'
            )
      );


    -- -----------------------------------------------------------------------
    -- FINAL ASSERTIONS
    -- -----------------------------------------------------------------------

    IF v_projection_rows <> 966 THEN

        RAISE EXCEPTION
            'Gate 4.3 projection row-count failure: expected 966, found %.',
            v_projection_rows;


    ELSIF v_projection_distinct_ids <> 966 THEN

        RAISE EXCEPTION
            'Gate 4.3 projection identity failure: expected 966 distinct course_id values, found %.',
            v_projection_distinct_ids;


    ELSIF v_candidate_missing <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.3 candidate-to-projection missing rows: %.',
            v_candidate_missing;


    ELSIF v_projection_missing <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.3 projection-to-candidate missing rows: %.',
            v_projection_missing;


    ELSIF v_hash_mismatches <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.3 candidate/projection hash mismatches: %.',
            v_hash_mismatches;


    ELSIF v_wrong_refresh_run <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.3 rows referencing the wrong refresh run: %.',
            v_wrong_refresh_run;


    ELSIF v_wrong_as_of <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.3 rows with inconsistent report_as_of_utc: %.',
            v_wrong_as_of;


    ELSIF v_projection_checksum
          IS DISTINCT FROM
          v_candidate_checksum
    THEN

        RAISE EXCEPTION
            'Gate 4.3 projection/candidate checksum mismatch: projection %, candidate %.',
            coalesce
            (
                v_projection_checksum,
                '<NULL>'
            ),
            coalesce
            (
                v_candidate_checksum,
                '<NULL>'
            );


    ELSIF v_projection_checksum
          IS DISTINCT FROM
          '666d67d56d4c492ea0cdd7a63a7f85fd'
    THEN

        RAISE EXCEPTION
            'Gate 4.3 frozen checksum failure: expected %, found %.',
            '666d67d56d4c492ea0cdd7a63a7f85fd',
            coalesce
            (
                v_projection_checksum,
                '<NULL>'
            );


    ELSIF v_refresh_run_count <> 1

       OR v_completed_run_count <> 1

       OR v_total_refresh_run_count <> 1
    THEN

        RAISE EXCEPTION
            'Gate 4.3 refresh-run completion failure: current run count %, completed count %, total refresh-run rows %.',
            v_refresh_run_count,
            v_completed_run_count,
            v_total_refresh_run_count;


    ELSIF v_source_row_count <> 966 THEN

        RAISE EXCEPTION
            'Gate 4.3 refresh source-row count failure: expected 966, found %.',
            v_source_row_count;


    ELSIF v_rows_inserted <> 966

       OR v_rows_updated <> 0

       OR v_rows_deleted <> 0

       OR v_rows_unchanged <> 0
    THEN

        RAISE EXCEPTION
            'Gate 4.3 first-population metric failure: expected inserted 966, updated 0, deleted 0, unchanged 0; found inserted %, updated %, deleted %, unchanged %.',
            v_rows_inserted,
            v_rows_updated,
            v_rows_deleted,
            v_rows_unchanged;


    ELSIF v_refresh_checksum
          IS DISTINCT FROM
          '666d67d56d4c492ea0cdd7a63a7f85fd'
    THEN

        RAISE EXCEPTION
            'Gate 4.3 refresh-run checksum failure: expected %, found %.',
            '666d67d56d4c492ea0cdd7a63a7f85fd',
            coalesce
            (
                v_refresh_checksum,
                '<NULL>'
            );


    ELSIF v_current_rows <> 966

       OR v_distinct_course_ids <> 966

       OR v_required_failures <> 0

       OR v_duplicate_source_groups <> 0
    THEN

        RAISE EXCEPTION
            'Gate 4.3 post-refresh core baseline failure: rows %, distinct %, required failures %, duplicate groups %.',
            v_current_rows,
            v_distinct_course_ids,
            v_required_failures,
            v_duplicate_source_groups;


    ELSIF v_second_rows <> 5

       OR v_prior_rows <> 961

       OR v_other_rows <> 0
    THEN

        RAISE EXCEPTION
            'Gate 4.3 post-refresh lineage failure: second %, prior %, other %.',
            v_second_rows,
            v_prior_rows,
            v_other_rows;


    ELSIF v_second_promoted <> 1

       OR v_prior_promoted <> 1
    THEN

        RAISE EXCEPTION
            'Gate 4.3 post-refresh batch lifecycle failure: second %, prior %.',
            v_second_promoted,
            v_prior_promoted;


    ELSIF v_unauthorized_relations <> 0

       OR v_reporting_routines <> 0

       OR v_user_triggers <> 0

       OR v_policies <> 0

       OR v_standalone_indexes <> 0
    THEN

        RAISE EXCEPTION
            'Gate 4.3 unauthorized reporting-object failure: relations %, routines %, triggers %, policies %, standalone indexes %.',
            v_unauthorized_relations,
            v_reporting_routines,
            v_user_triggers,
            v_policies,
            v_standalone_indexes;

    END IF;


    RAISE NOTICE
        'Gate 4.3 validation PASS: projection %, distinct IDs %, refresh runs %, inserted %, updated %, deleted %, unchanged %, checksum %.',
        v_projection_rows,
        v_projection_distinct_ids,
        v_total_refresh_run_count,
        v_rows_inserted,
        v_rows_updated,
        v_rows_deleted,
        v_rows_unchanged,
        v_projection_checksum;

END

$gate4_3_post_validate$;


-- ===========================================================================
-- 13. REVIEWABLE CURRENT REFRESH-RUN EVIDENCE
-- ===========================================================================

SELECT

    run.run_id,

    run.projection_name,

    run.started_at,

    run.completed_at,

    run.source_row_count,

    run.rows_inserted,

    run.rows_updated,

    run.rows_deleted,

    run.rows_unchanged,

    run.business_checksum,

    run.status,

    run.source_filter,

    run.source_state,

    run.error_information

FROM reporting.projection_refresh_run run

JOIN gate4_3_refresh_context ctx
  ON ctx.run_id = run.run_id;


-- ===========================================================================
-- 14. REVIEWABLE PROJECTION EVIDENCE
-- ===========================================================================

SELECT

    count(*)
        AS projection_rows,

    count(DISTINCT course_id)
        AS distinct_course_ids,

    count(DISTINCT report_refresh_run_id)
        AS distinct_refresh_run_ids,

    count(DISTINCT report_as_of_utc)
        AS distinct_report_as_of_values,

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
    AS projection_checksum

FROM reporting.course_current_catalog;


-- ===========================================================================
-- 15. REVIEWABLE CANDIDATE / PROJECTION RECONCILIATION
-- ===========================================================================

SELECT

    (
        SELECT count(*)

        FROM gate4_3_candidate
    )
    AS candidate_rows,

    (
        SELECT count(*)

        FROM reporting.course_current_catalog
    )
    AS projection_rows,

    (
        SELECT count(*)

        FROM gate4_3_candidate candidate

        LEFT JOIN reporting.course_current_catalog projection
          ON projection.course_id = candidate.course_id

        WHERE projection.course_id IS NULL
    )
    AS candidate_missing_from_projection,

    (
        SELECT count(*)

        FROM reporting.course_current_catalog projection

        LEFT JOIN gate4_3_candidate candidate
          ON candidate.course_id = projection.course_id

        WHERE candidate.course_id IS NULL
    )
    AS projection_missing_from_candidate,

    (
        SELECT count(*)

        FROM gate4_3_candidate candidate

        JOIN reporting.course_current_catalog projection
          ON projection.course_id = candidate.course_id

        WHERE projection.business_row_hash
              IS DISTINCT FROM
              candidate.business_row_hash
    )
    AS business_hash_mismatches;


-- ===========================================================================
-- 16. RECOMPUTED GATE 4.3 ACCEPTANCE EVIDENCE
--
-- Expected values and observed values are deliberately shown separately.
-- Observed values are recomputed from the transaction state.
-- ===========================================================================

SELECT

    966::bigint
        AS expected_projection_rows,

    (
        SELECT count(*)

        FROM reporting.course_current_catalog
    )
        AS observed_projection_rows,


    966::bigint
        AS expected_distinct_course_ids,

    (
        SELECT count(DISTINCT course_id)

        FROM reporting.course_current_catalog
    )
        AS observed_distinct_course_ids,


    1::bigint
        AS expected_refresh_run_rows,

    (
        SELECT count(*)

        FROM reporting.projection_refresh_run
    )
        AS observed_refresh_run_rows,


    966::bigint
        AS expected_rows_inserted,

    ctx.rows_inserted
        AS observed_rows_inserted,


    0::bigint
        AS expected_rows_updated,

    ctx.rows_updated
        AS observed_rows_updated,


    0::bigint
        AS expected_rows_deleted,

    ctx.rows_deleted
        AS observed_rows_deleted,


    0::bigint
        AS expected_rows_unchanged,

    ctx.rows_unchanged
        AS observed_rows_unchanged,


    '666d67d56d4c492ea0cdd7a63a7f85fd'
        AS expected_projection_checksum,

    (
        SELECT

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

        FROM reporting.course_current_catalog
    )
        AS observed_projection_checksum,


    CASE

        WHEN
        (
            SELECT count(*)

            FROM reporting.course_current_catalog
        ) = 966

        AND
        (
            SELECT count(DISTINCT course_id)

            FROM reporting.course_current_catalog
        ) = 966

        AND
        (
            SELECT count(*)

            FROM reporting.projection_refresh_run
        ) = 1

        AND ctx.rows_inserted = 966

        AND ctx.rows_updated = 0

        AND ctx.rows_deleted = 0

        AND ctx.rows_unchanged = 0

        AND
        (
            SELECT

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

            FROM reporting.course_current_catalog
        )
        IS NOT DISTINCT FROM
        '666d67d56d4c492ea0cdd7a63a7f85fd'

        THEN 'PASS'

        ELSE 'FAIL'

    END
        AS gate_4_3_recomputed_evidence_status

FROM gate4_3_refresh_context ctx;


-- ===========================================================================
-- 17. FINAL TRANSACTION ACTION
--
-- AUTHORITATIVE VERSION:
--
--     COMMIT;
--
-- DO NOT EXECUTE THIS VERSION YET.
--
-- After this complete file is saved and passes static validation, create a
-- separately fingerprinted rehearsal copy that is byte-for-byte equivalent
-- except that the final executable statement below is changed from:
--
--     COMMIT;
--
-- to:
--
--     ROLLBACK;
--
-- Gate 4.3 rehearsal acceptance requires:
--
--   temporary projection rows             966
--   temporary distinct course_id          966
--   temporary refresh-run rows            1
--   temporary refresh status              COMPLETED
--   temporary rows_inserted               966
--   temporary rows_updated                0
--   temporary rows_deleted                0
--   temporary rows_unchanged              0
--   temporary checksum                    666d67d56d4c492ea0cdd7a63a7f85fd
--   psql exit code                        0
--   final transaction action              ROLLBACK
--
-- Post-ROLLBACK state must return to:
--
--   reporting.projection_refresh_run      0 rows
--   reporting.course_current_catalog      0 rows
--
-- The authoritative COMMIT version remains frozen until rehearsal,
-- post-rollback verification, fingerprint verification, and separate
-- explicit COMMIT authorization all pass.
-- ===========================================================================
ROLLBACK;