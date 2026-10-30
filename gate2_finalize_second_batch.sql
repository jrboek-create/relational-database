-- Gate 3: finalize second Worldwide Catalog batch
-- Batch: 53e0ae11-6a25-4f0a-9beb-814c8c3d1946
-- Changes lifecycle metadata only.

BEGIN;

SET LOCAL lock_timeout = '10s';

SELECT pg_advisory_xact_lock(
    hashtext(
        'gate3:WW_CATALOG:finalize:53e0ae11-6a25-4f0a-9beb-814c8c3d1946'
    )
);

DO $finalize$
DECLARE
    v_stage_status text;
    v_completed_at timestamptz;
    v_core_status text;
    v_course_count bigint;
    v_new_lineage bigint;
    v_prior_lineage bigint;
BEGIN

    -- Staging batch must be ready or already finalized.
    SELECT status, completed_at
    INTO STRICT v_stage_status, v_completed_at
    FROM staging._phase2_batches
    WHERE batch_id =
        '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
      AND file_count = 1
      AND component_count = 1
      AND failure_count = 0;

    -- Component 52 must remain valid.
    IF NOT EXISTS (
        SELECT 1
        FROM staging._phase2_components
        WHERE component_id = 52
          AND last_import_batch =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
          AND status = 'SUCCEEDED'
          AND staged_rows = 966
          AND source_hash =
              'c28dfafdcf5ec41e4f3a0fc2992f90ebac8c8bbdf75c55526d8a6a14cccc65f9'
          AND staging_table =
              'raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd'
    ) THEN
        RAISE EXCEPTION 'Component 52 validation failed';
    END IF;

    -- Core Import Batch must be ready or already finalized.
    SELECT ib.batch_status
    INTO STRICT v_core_status
    FROM core.import_batch ib
    JOIN core.source_system ss
      ON ss.source_system_id = ib.source_system_id
    WHERE ib.import_batch_id =
          '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
      AND ss.source_system_id =
          'a5d205bc-fd64-4d07-b437-c4440425be42'::uuid
      AND ss.system_code = 'WW_CATALOG'
      AND ib.source_fingerprint =
          'c28dfafdcf5ec41e4f3a0fc2992f90ebac8c8bbdf75c55526d8a6a14cccc65f9'
      AND ib.authoritative_indicator = false;

    -- Verify Course population and lineage before finalization.
    SELECT count(*)
    INTO v_course_count
    FROM core.course c
    JOIN core.import_batch ib
      ON ib.import_batch_id = c.import_batch_id
    JOIN core.source_system ss
      ON ss.source_system_id = ib.source_system_id
    WHERE ss.system_code = 'WW_CATALOG'
      AND c.is_current IS TRUE;

    SELECT count(*)
    INTO v_new_lineage
    FROM core.course
    WHERE import_batch_id =
        '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid;

    SELECT count(*)
    INTO v_prior_lineage
    FROM core.course
    WHERE import_batch_id =
        '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid;

    IF v_course_count <> 966
       OR v_new_lineage <> 5
       OR v_prior_lineage <> 961
    THEN
        RAISE EXCEPTION
            'Pre-finalization reconciliation failed: courses=%, new_lineage=%, prior_lineage=%',
            v_course_count,
            v_new_lineage,
            v_prior_lineage;
    END IF;

    -- First finalization.
    IF v_stage_status = 'STARTED'
       AND v_completed_at IS NULL
       AND v_core_status = 'REGISTERED'
    THEN

        UPDATE core.import_batch
        SET batch_status = 'PROMOTED'
        WHERE import_batch_id =
            '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
          AND batch_status = 'REGISTERED';

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Core Import Batch finalization failed';
        END IF;

        UPDATE staging._phase2_batches
        SET
            status = 'STAGED',
            completed_at = clock_timestamp()
        WHERE batch_id =
            '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
          AND status = 'STARTED'
          AND completed_at IS NULL;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staging batch finalization failed';
        END IF;

    -- Safe rerun.
    ELSIF v_stage_status = 'STAGED'
       AND v_completed_at IS NOT NULL
       AND v_core_status = 'PROMOTED'
    THEN
        NULL;

    ELSE
        RAISE EXCEPTION
            'Unexpected lifecycle state: staging=%, completed_at=%, core=%',
            v_stage_status,
            v_completed_at,
            v_core_status;
    END IF;

END
$finalize$;

-- Post-finalization verification.
SELECT
    sb.batch_id,
    sb.status AS staging_status,
    sb.completed_at,
    pc.status AS component_status,
    pc.staged_rows,
    ib.batch_status AS core_batch_status,
    ib.authoritative_indicator,
    (
        SELECT count(*)
        FROM core.course c
        JOIN core.import_batch cib
          ON cib.import_batch_id = c.import_batch_id
        JOIN core.source_system ss
          ON ss.source_system_id = cib.source_system_id
        WHERE ss.system_code = 'WW_CATALOG'
          AND c.is_current IS TRUE
    ) AS current_course_rows,
    (
        SELECT count(*)
        FROM core.course
        WHERE import_batch_id =
            '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
    ) AS new_batch_lineage_rows,
    (
        SELECT count(*)
        FROM core.course
        WHERE import_batch_id =
            '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
    ) AS prior_batch_lineage_rows,
    CASE
        WHEN sb.status = 'STAGED'
         AND sb.completed_at IS NOT NULL
         AND pc.status = 'SUCCEEDED'
         AND pc.staged_rows = 966
         AND ib.batch_status = 'PROMOTED'
         AND ib.authoritative_indicator = false
         AND (
             SELECT count(*)
             FROM core.course c
             JOIN core.import_batch cib
               ON cib.import_batch_id = c.import_batch_id
             JOIN core.source_system ss
               ON ss.source_system_id = cib.source_system_id
             WHERE ss.system_code = 'WW_CATALOG'
               AND c.is_current IS TRUE
         ) = 966
         AND (
             SELECT count(*)
             FROM core.course
             WHERE import_batch_id =
                 '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
         ) = 5
         AND (
             SELECT count(*)
             FROM core.course
             WHERE import_batch_id =
                 '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
         ) = 961
        THEN 'PASS'
        ELSE 'FAIL'
    END AS finalization_reconciliation
FROM staging._phase2_batches sb
JOIN staging._phase2_components pc
  ON pc.component_id = 52
JOIN core.import_batch ib
  ON ib.import_batch_id = sb.batch_id
WHERE sb.batch_id =
    '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid;

COMMIT;