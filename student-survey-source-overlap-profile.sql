\set ON_ERROR_STOP on

WITH source_responses AS (
    SELECT DISTINCT
        34 AS component_id,
        'NEW_RAW'::text AS source_version,
        NULLIF(BTRIM(c0001), '') AS response_id
    FROM staging.raw_master_online_new_s01_rawdata_3caa2498
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        35,
        'NEW_SPOTS'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_new_s02_spots_3caa2498
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        37,
        'OLD_P1'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_part_s01_online_31fb6e24
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        40,
        'OLD_P2'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_part_s01_online_3417e822
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        41,
        'OLD_P3'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_part_s01_online_324dd997
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        42,
        'OLD_P4'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_part_s01_online_6164ddea
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL
),
response_profile AS (
    SELECT
        response_id,
        COUNT(DISTINCT component_id)::bigint
            AS component_count
    FROM source_responses
    GROUP BY response_id
),
source_contribution AS (
    SELECT
        s.component_id,
        s.source_version,
        COUNT(*)::bigint AS distinct_response_ids,

        SUM(
            CASE
                WHEN p.component_count = 1
                THEN 1
                ELSE 0
            END
        )::bigint AS exclusive_response_ids,

        SUM(
            CASE
                WHEN p.component_count > 1
                THEN 1
                ELSE 0
            END
        )::bigint AS shared_response_ids

    FROM source_responses s

    JOIN response_profile p
        ON p.response_id = s.response_id

    GROUP BY
        s.component_id,
        s.source_version
),
overall AS (
    SELECT
        COUNT(*)::bigint AS total_distinct_response_ids,

        SUM(
            CASE
                WHEN component_count = 1
                THEN 1
                ELSE 0
            END
        )::bigint AS responses_in_one_component,

        SUM(
            CASE
                WHEN component_count > 1
                THEN 1
                ELSE 0
            END
        )::bigint AS responses_in_multiple_components

    FROM response_profile
)
SELECT
    c.component_id,
    c.source_version,
    c.distinct_response_ids,
    c.exclusive_response_ids,
    c.shared_response_ids,
    o.total_distinct_response_ids,
    o.responses_in_one_component,
    o.responses_in_multiple_components
FROM source_contribution c
CROSS JOIN overall o
ORDER BY c.component_id;

WITH source_responses AS (
    SELECT DISTINCT
        34 AS component_id,
        'NEW_RAW'::text AS source_version,
        NULLIF(BTRIM(c0001), '') AS response_id
    FROM staging.raw_master_online_new_s01_rawdata_3caa2498
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        35,
        'NEW_SPOTS'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_new_s02_spots_3caa2498
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        37,
        'OLD_P1'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_part_s01_online_31fb6e24
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        40,
        'OLD_P2'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_part_s01_online_3417e822
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        41,
        'OLD_P3'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_part_s01_online_324dd997
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        42,
        'OLD_P4'::text,
        NULLIF(BTRIM(c0001), '')
    FROM staging.raw_master_online_part_s01_online_6164ddea
    WHERE NULLIF(BTRIM(c0001), '') IS NOT NULL
),
sources AS (
    SELECT DISTINCT
        component_id,
        source_version
    FROM source_responses
),
pairs AS (
    SELECT
        a.component_id AS component_a,
        a.source_version AS source_a,
        b.component_id AS component_b,
        b.source_version AS source_b
    FROM sources a
    JOIN sources b
        ON a.component_id < b.component_id
)
SELECT
    p.component_a,
    p.source_a,
    p.component_b,
    p.source_b,
    COUNT(DISTINCT a.response_id)::bigint
        AS overlapping_response_ids
FROM pairs p
LEFT JOIN source_responses a
    ON a.component_id = p.component_a
LEFT JOIN source_responses b
    ON b.component_id = p.component_b
   AND b.response_id = a.response_id
WHERE b.response_id IS NOT NULL
GROUP BY
    p.component_a,
    p.source_a,
    p.component_b,
    p.source_b
ORDER BY
    p.component_a,
    p.component_b;
