-- Gate 3 incremental Worldwide Catalog Course promotion
-- Controlled transaction for staging batch 53e0ae11-6a25-4f0a-9beb-814c8c3d1946
-- First run: 2 INSERT, 3 title-only UPDATE, 961 UNCHANGED
-- Safe rerun: 0 INSERT, 0 UPDATE, 966 UNCHANGED

BEGIN;

SET LOCAL lock_timeout = '10s';

SELECT pg_advisory_xact_lock(
    hashtext('gate3:WW_CATALOG:incremental-course:53e0ae11-6a25-4f0a-9beb-814c8c3d1946')
);

CREATE TEMP TABLE g3_metrics (
    inserted_this_run bigint,
    updated_this_run bigint,
    existing_before bigint
) ON COMMIT DROP;

CREATE TEMP TABLE g3_uuid_before ON COMMIT DROP AS
SELECT
    c.source_identifier,
    c.course_id
FROM core.course c
JOIN core.import_batch ib
    ON ib.import_batch_id = c.import_batch_id
JOIN core.source_system ss
    ON ss.source_system_id = ib.source_system_id
WHERE ss.system_code = 'WW_CATALOG'
  AND c.is_current IS TRUE
  AND c.source_identifier IN ('200001','200002','200003');

CREATE TEMP TABLE g3_pre ON COMMIT DROP AS
WITH s AS (
    SELECT
        source_row_number,
        c0001::text AS univ_course_id,
        c0002::text AS course_code,
        c0003::text AS course_title,
        count(*) OVER (PARTITION BY c0001) AS source_id_rows,
        count(*) OVER (PARTITION BY c0002) AS source_code_rows,
        count(*) OVER (PARTITION BY c0001,c0002) AS source_pair_rows
    FROM staging.raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd
),
r AS (
    SELECT
        s.*,
        im.match_count AS id_match_count,
        im.core_id AS id_core_uuid,
        cm.match_count AS code_match_count,
        cm.core_id AS code_core_uuid,
        ic.course_code AS core_course_code,
        ic.course_title AS core_course_title
    FROM s
    LEFT JOIN LATERAL (
        SELECT
            count(*)::bigint AS match_count,
            min(c.course_id::text) AS core_id
        FROM core.course c
        JOIN core.import_batch ib
            ON ib.import_batch_id = c.import_batch_id
        JOIN core.source_system ss
            ON ss.source_system_id = ib.source_system_id
        WHERE ss.system_code = 'WW_CATALOG'
          AND c.is_current IS TRUE
          AND c.source_identifier = s.univ_course_id
    ) im ON true
    LEFT JOIN LATERAL (
        SELECT
            count(*)::bigint AS match_count,
            min(c.course_id::text) AS core_id
        FROM core.course c
        JOIN core.import_batch ib
            ON ib.import_batch_id = c.import_batch_id
        JOIN core.source_system ss
            ON ss.source_system_id = ib.source_system_id
        WHERE ss.system_code = 'WW_CATALOG'
          AND c.is_current IS TRUE
          AND c.course_code = s.course_code
    ) cm ON true
    LEFT JOIN core.course ic
        ON im.match_count = 1
       AND ic.course_id::text = im.core_id
)
SELECT
    source_row_number,
    univ_course_id,
    course_code,
    course_title,
    id_match_count,
    code_match_count,
    id_core_uuid,
    code_core_uuid,
    CASE
        WHEN univ_course_id IS NULL
          OR btrim(univ_course_id) = ''
          OR course_code IS NULL
          OR btrim(course_code) = ''
            THEN 'EXCEPTION'

        WHEN source_id_rows > 1
          OR source_code_rows > 1
          OR source_pair_rows > 1
          OR id_match_count > 1
          OR code_match_count > 1
            THEN 'DUPLICATE'

        WHEN id_match_count = 1
         AND code_match_count = 1
         AND id_core_uuid <> code_core_uuid
            THEN 'IDENTITY_CONFLICT'

        WHEN id_match_count = 1
         AND (
                core_course_code IS DISTINCT FROM course_code
             OR core_course_title IS DISTINCT FROM course_title
         )
            THEN 'UPDATE'

        WHEN id_match_count = 1
            THEN 'UNCHANGED'

        WHEN id_match_count = 0
         AND code_match_count = 1
            THEN 'CROSSWALK_REVIEW'

        WHEN id_match_count = 0
         AND code_match_count = 0
            THEN 'INSERT'

        ELSE 'EXCEPTION'
    END AS disposition,

    CASE
        WHEN id_match_count = 1 THEN
            concat_ws(
                '|',
                CASE
                    WHEN core_course_code IS DISTINCT FROM course_code
                    THEN 'course_code'
                END,
                CASE
                    WHEN core_course_title IS DISTINCT FROM course_title
                    THEN 'course_title'
                END
            )
        ELSE ''
    END AS changed_fields
FROM r;

DO $promote$
DECLARE
    v_insert bigint;
    v_update bigint;
    v_unchanged bigint;
    v_other bigint;
    v_existing bigint;
    v_inserted bigint;
    v_updated bigint;
    v_count bigint;
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM staging._phase2_batches
        WHERE batch_id =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
          AND status = 'STARTED'
          AND completed_at IS NULL
          AND file_count = 1
          AND component_count = 1
          AND failure_count = 0
    ) THEN
        RAISE EXCEPTION
            'Incremental staging batch is not in the expected STARTED state';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM staging._phase2_components
        WHERE component_id = 52
          AND last_import_batch =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
          AND source_hash =
              'c28dfafdcf5ec41e4f3a0fc2992f90ebac8c8bbdf75c55526d8a6a14cccc65f9'
          AND staging_table =
              'raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd'
          AND status = 'SUCCEEDED'
          AND staged_rows = 966
    ) THEN
        RAISE EXCEPTION
            'Component 52 validation failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1
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
          AND ib.authoritative_indicator = false
          AND ib.batch_status = 'REGISTERED'
    ) THEN
        RAISE EXCEPTION
            'Incremental core import-batch lineage validation failed';
    END IF;

    SELECT count(*)
    INTO v_count
    FROM staging.raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd;

    IF v_count <> 966 THEN
        RAISE EXCEPTION
            'Expected 966 staged rows; found %',
            v_count;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM staging.raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd
        GROUP BY c0001
        HAVING count(*) > 1
    )
    OR EXISTS (
        SELECT 1
        FROM staging.raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd
        GROUP BY c0002
        HAVING count(*) > 1
    )
    OR EXISTS (
        SELECT 1
        FROM staging.raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd
        GROUP BY c0001,c0002
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION
            'Duplicate incremental source identity detected';
    END IF;

    IF (SELECT count(*) FROM g3_uuid_before) <> 3 THEN
        RAISE EXCEPTION
            'Expected three existing UPDATE Course UUIDs';
    END IF;

    SELECT
        count(*) FILTER (WHERE disposition = 'INSERT'),
        count(*) FILTER (WHERE disposition = 'UPDATE'),
        count(*) FILTER (WHERE disposition = 'UNCHANGED'),
        count(*) FILTER (
            WHERE disposition NOT IN ('INSERT','UPDATE','UNCHANGED')
        )
    INTO
        v_insert,
        v_update,
        v_unchanged,
        v_other
    FROM g3_pre;

    SELECT count(*)
    INTO v_existing
    FROM core.course c
    JOIN core.import_batch ib
        ON ib.import_batch_id = c.import_batch_id
    JOIN core.source_system ss
        ON ss.source_system_id = ib.source_system_id
    WHERE ss.system_code = 'WW_CATALOG'
      AND c.is_current IS TRUE;

    IF v_insert = 2
       AND v_update = 3
       AND v_unchanged = 961
       AND v_other = 0
       AND v_existing = 964
    THEN

        IF (
            SELECT count(*)
            FROM g3_pre
            WHERE disposition = 'INSERT'
              AND (univ_course_id,course_code) IN (
                    ('999999','TSTG 900'),
                    ('999998','TSTG 901')
              )
        ) <> 2 THEN
            RAISE EXCEPTION
                'Expected INSERT identities were not found';
        END IF;

        IF (
            SELECT count(*)
            FROM g3_pre
            WHERE disposition = 'UPDATE'
              AND changed_fields = 'course_title'
              AND (univ_course_id,course_code) IN (
                    ('200001','AASI 605'),
                    ('200002','AASI 607'),
                    ('200003','AASI 611')
              )
        ) <> 3 THEN
            RAISE EXCEPTION
                'Expected title-only UPDATE identities were not found';
        END IF;

    ELSIF NOT (
        v_insert = 0
        AND v_update = 0
        AND v_unchanged = 966
        AND v_other = 0
        AND v_existing = 966
    ) THEN
        RAISE EXCEPTION
            'Unexpected pre-promotion state: INSERT=%, UPDATE=%, UNCHANGED=%, OTHER=%, CORE=%',
            v_insert,
            v_update,
            v_unchanged,
            v_other,
            v_existing;
    END IF;

    INSERT INTO core.course (
        course_code,
        course_title,
        academic_level_code,
        organization_id,
        import_batch_id,
        source_identifier,
        source_record_locator,
        source_version_label,
        effective_from,
        effective_to,
        is_current
    )
    SELECT
        p.course_code,
        p.course_title,
        NULL,
        NULL,
        '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,
        p.univ_course_id,
        'catalog-WW-2026-09-28-GATE3-TEST.csv|component=52|source_row='
            || p.source_row_number::text,
        'catalog-WW-2026-09-28-GATE3-TEST.csv',
        NULL,
        NULL,
        true
    FROM g3_pre p
    WHERE p.disposition = 'INSERT'
    ORDER BY p.source_row_number;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    UPDATE core.course c
    SET
        course_title = p.course_title,
        import_batch_id =
            '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,
        source_record_locator =
            'catalog-WW-2026-09-28-GATE3-TEST.csv|component=52|source_row='
            || p.source_row_number::text,
        source_version_label =
            'catalog-WW-2026-09-28-GATE3-TEST.csv',
        is_current = true
    FROM g3_pre p
    WHERE p.disposition = 'UPDATE'
      AND p.changed_fields = 'course_title'
      AND c.course_id::text = p.id_core_uuid
      AND c.source_identifier = p.univ_course_id;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF NOT (
        (v_existing = 964 AND v_inserted = 2 AND v_updated = 3)
        OR
        (v_existing = 966 AND v_inserted = 0 AND v_updated = 0)
    ) THEN
        RAISE EXCEPTION
            'Unexpected promotion counts: existing=%, inserted=%, updated=%',
            v_existing,
            v_inserted,
            v_updated;
    END IF;

    INSERT INTO g3_metrics
    VALUES (
        v_inserted,
        v_updated,
        v_existing
    );

END
$promote$;

CREATE TEMP TABLE g3_post ON COMMIT DROP AS
WITH s AS (
    SELECT
        source_row_number,
        c0001::text AS univ_course_id,
        c0002::text AS course_code,
        c0003::text AS course_title
    FROM staging.raw_catalog_ww_2026_09_28_gate3_test_s01_csv_c28dfafd
),
r AS (
    SELECT
        s.*,
        im.match_count AS id_match_count,
        im.core_id AS id_core_uuid,
        cm.match_count AS code_match_count,
        cm.core_id AS code_core_uuid,
        ic.course_code AS core_course_code,
        ic.course_title AS core_course_title
    FROM s
    LEFT JOIN LATERAL (
        SELECT
            count(*)::bigint AS match_count,
            min(c.course_id::text) AS core_id
        FROM core.course c
        JOIN core.import_batch ib
            ON ib.import_batch_id = c.import_batch_id
        JOIN core.source_system ss
            ON ss.source_system_id = ib.source_system_id
        WHERE ss.system_code = 'WW_CATALOG'
          AND c.is_current IS TRUE
          AND c.source_identifier = s.univ_course_id
    ) im ON true
    LEFT JOIN LATERAL (
        SELECT
            count(*)::bigint AS match_count,
            min(c.course_id::text) AS core_id
        FROM core.course c
        JOIN core.import_batch ib
            ON ib.import_batch_id = c.import_batch_id
        JOIN core.source_system ss
            ON ss.source_system_id = ib.source_system_id
        WHERE ss.system_code = 'WW_CATALOG'
          AND c.is_current IS TRUE
          AND c.course_code = s.course_code
    ) cm ON true
    LEFT JOIN core.course ic
        ON im.match_count = 1
       AND ic.course_id::text = im.core_id
)
SELECT
    source_row_number,
    univ_course_id,
    course_code,
    course_title,
    id_match_count,
    code_match_count,
    id_core_uuid,
    code_core_uuid,
    CASE
        WHEN id_match_count > 1
          OR code_match_count > 1
            THEN 'DUPLICATE'

        WHEN id_match_count = 1
         AND code_match_count = 1
         AND id_core_uuid <> code_core_uuid
            THEN 'IDENTITY_CONFLICT'

        WHEN id_match_count = 1
         AND (
                core_course_code IS DISTINCT FROM course_code
             OR core_course_title IS DISTINCT FROM course_title
         )
            THEN 'UPDATE'

        WHEN id_match_count = 1
            THEN 'UNCHANGED'

        WHEN id_match_count = 0
         AND code_match_count = 1
            THEN 'CROSSWALK_REVIEW'

        WHEN id_match_count = 0
         AND code_match_count = 0
            THEN 'INSERT'

        ELSE 'EXCEPTION'
    END AS disposition
FROM r;

DO $post$
DECLARE
    v_count bigint;
BEGIN

    IF (SELECT count(*) FROM g3_post) <> 966
       OR (
            SELECT count(*)
            FROM g3_post
            WHERE disposition = 'UNCHANGED'
       ) <> 966
       OR EXISTS (
            SELECT 1
            FROM g3_post
            WHERE disposition <> 'UNCHANGED'
       )
    THEN
        RAISE EXCEPTION
            'Post-promotion classification is not exactly 966 UNCHANGED';
    END IF;

    SELECT count(*)
    INTO v_count
    FROM core.course c
    JOIN core.import_batch ib
        ON ib.import_batch_id = c.import_batch_id
    JOIN core.source_system ss
        ON ss.source_system_id = ib.source_system_id
    WHERE ss.system_code = 'WW_CATALOG'
      AND c.is_current IS TRUE;

    IF v_count <> 966 THEN
        RAISE EXCEPTION
            'Expected 966 current WW_CATALOG Courses; found %',
            v_count;
    END IF;

    IF (
        SELECT count(*)
        FROM g3_uuid_before b
        JOIN core.course c
          ON c.course_id = b.course_id
         AND c.source_identifier = b.source_identifier
    ) <> 3 THEN
        RAISE EXCEPTION
            'One or more UPDATE Course UUIDs changed';
    END IF;

    IF (
        SELECT count(*)
        FROM core.course
        WHERE import_batch_id =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
          AND source_identifier IN (
                '200001',
                '200002',
                '200003',
                '999998',
                '999999'
          )
    ) <> 5 THEN
        RAISE EXCEPTION
            'Expected five promoted rows with new-batch lineage';
    END IF;

    IF (
        SELECT count(*)
        FROM core.course
        WHERE import_batch_id =
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
          AND source_identifier NOT IN (
                '200001',
                '200002',
                '200003',
                '999998',
                '999999'
          )
    ) <> 961 THEN
        RAISE EXCEPTION
            'The 961 unchanged Course rows were not left untouched';
    END IF;

END
$post$;

WITH
categories(disposition,sort_order) AS (
    VALUES
        ('INSERT',1),
        ('UPDATE',2),
        ('UNCHANGED',3),
        ('CROSSWALK_REVIEW',4),
        ('IDENTITY_CONFLICT',5),
        ('DUPLICATE',6),
        ('EXCEPTION',7)
),
counts AS (
    SELECT
        disposition,
        count(*)::bigint AS row_count
    FROM g3_post
    GROUP BY disposition
),
core_metrics AS (
    SELECT
        count(*)::bigint AS current_core_course_rows
    FROM core.course c
    JOIN core.import_batch ib
        ON ib.import_batch_id = c.import_batch_id
    JOIN core.source_system ss
        ON ss.source_system_id = ib.source_system_id
    WHERE ss.system_code = 'WW_CATALOG'
      AND c.is_current IS TRUE
),
checks AS (
    SELECT
        (
            SELECT count(*)
            FROM g3_uuid_before b
            JOIN core.course c
              ON c.course_id = b.course_id
             AND c.source_identifier = b.source_identifier
        )::bigint AS preserved_update_uuids,

        (
            SELECT count(*)
            FROM core.course
            WHERE import_batch_id =
                  '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
              AND source_identifier IN (
                    '200001',
                    '200002',
                    '200003',
                    '999998',
                    '999999'
              )
        )::bigint AS new_batch_lineage_rows,

        (
            SELECT count(*)
            FROM core.course
            WHERE import_batch_id =
                  '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
              AND source_identifier NOT IN (
                    '200001',
                    '200002',
                    '200003',
                    '999998',
                    '999999'
              )
        )::bigint AS untouched_prior_lineage_rows
)
SELECT
    cat.disposition,
    coalesce(cnt.row_count,0) AS row_count,
    966::bigint AS total_classified,
    966::bigint AS expected_rows,
    m.inserted_this_run,
    m.updated_this_run,
    m.existing_before,
    cm.current_core_course_rows,
    ch.preserved_update_uuids,
    ch.new_batch_lineage_rows,
    ch.untouched_prior_lineage_rows,
    CASE
        WHEN coalesce(
            (
                SELECT row_count
                FROM counts
                WHERE disposition = 'UNCHANGED'
            ),
            0
        ) = 966
        AND coalesce(
            (
                SELECT sum(row_count)
                FROM counts
                WHERE disposition <> 'UNCHANGED'
            ),
            0
        ) = 0
        AND cm.current_core_course_rows = 966
        AND ch.preserved_update_uuids = 3
        AND ch.new_batch_lineage_rows = 5
        AND ch.untouched_prior_lineage_rows = 961
        THEN 'PASS'
        ELSE 'FAIL'
    END AS post_promotion_reconciliation
FROM categories cat
LEFT JOIN counts cnt
    USING(disposition)
CROSS JOIN g3_metrics m
CROSS JOIN core_metrics cm
CROSS JOIN checks ch
ORDER BY cat.sort_order;

COMMIT;