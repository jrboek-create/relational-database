\set ON_ERROR_STOP on

WITH source_rows AS (
    SELECT
        34 AS component_id,
        'NEW_RAW'::text AS source_version,
        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id
    FROM staging.raw_master_online_new_s01_rawdata_3caa2498

    UNION ALL

    SELECT
        35,
        'NEW_SPOTS'::text,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_new_s02_spots_3caa2498

    UNION ALL

    SELECT
        37,
        'OLD_P1'::text,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_31fb6e24

    UNION ALL

    SELECT
        40,
        'OLD_P2'::text,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_3417e822

    UNION ALL

    SELECT
        41,
        'OLD_P3'::text,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_324dd997

    UNION ALL

    SELECT
        42,
        'OLD_P4'::text,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_6164ddea
),

classified AS (
    SELECT
        component_id,
        source_version,
        response_id,
        course_code,
        unique_id,

        CASE
            WHEN response_id IS NULL THEN true
            WHEN LOWER(BTRIM(response_id)) IN (
                'responseuniqueid',
                'response unique id',
                'response_id',
                'responseid'
            ) THEN true
            ELSE false
        END AS is_header_or_empty

    FROM source_rows
),

valid_source_rows AS (
    SELECT
        component_id,
        source_version,
        response_id,
        course_code,
        unique_id

    FROM classified

    WHERE is_header_or_empty = false
),

response_profile AS (
    SELECT
        response_id,

        COUNT(
            DISTINCT component_id
        )::bigint AS component_count,

        COUNT(
            DISTINCT COALESCE(course_code, '')
        )::bigint AS course_value_count,

        COUNT(
            DISTINCT COALESCE(unique_id, '')
        )::bigint AS unique_id_value_count,

        STRING_AGG(
            DISTINCT component_id::text,
            ','
            ORDER BY component_id::text
        ) AS components

    FROM valid_source_rows

    GROUP BY response_id
),

shared_by_combination AS (
    SELECT
        components,

        COUNT(*)::bigint AS shared_response_ids,

        SUM(
            CASE
                WHEN course_value_count > 1
                THEN 1
                ELSE 0
            END
        )::bigint AS course_conflicts,

        SUM(
            CASE
                WHEN unique_id_value_count > 1
                THEN 1
                ELSE 0
            END
        )::bigint AS unique_id_conflicts

    FROM response_profile

    WHERE component_count > 1

    GROUP BY components
),

overall_summary AS (
    SELECT
        COUNT(*) FILTER (
            WHERE component_count > 1
        )::bigint AS shared_response_ids,

        COUNT(*) FILTER (
            WHERE component_count > 1
              AND course_value_count > 1
        )::bigint AS shared_ids_with_course_conflict,

        COUNT(*) FILTER (
            WHERE component_count > 1
              AND unique_id_value_count > 1
        )::bigint AS shared_ids_with_unique_id_conflict,

        COUNT(*) FILTER (
            WHERE component_count > 1
              AND components = '34,35'
        )::bigint AS new_raw_spots_shared_ids,

        COUNT(*) FILTER (
            WHERE component_count > 1
              AND components <> '34,35'
        )::bigint AS other_shared_ids

    FROM response_profile
),

header_summary AS (
    SELECT
        COUNT(*)::bigint AS header_or_empty_rows,

        COUNT(
            DISTINCT component_id
        )::bigint AS components_with_header_or_empty_rows

    FROM classified

    WHERE is_header_or_empty = true
)

SELECT
    'OVERALL'::text AS result_type,
    NULL::text AS components,

    o.shared_response_ids,
    o.shared_ids_with_course_conflict
        AS course_conflicts,
    o.shared_ids_with_unique_id_conflict
        AS unique_id_conflicts,

    o.new_raw_spots_shared_ids,
    o.other_shared_ids,

    h.header_or_empty_rows,
    h.components_with_header_or_empty_rows

FROM overall_summary o

CROSS JOIN header_summary h

UNION ALL

SELECT
    'COMPONENT_COMBINATION'::text,
    s.components,

    s.shared_response_ids,
    s.course_conflicts,
    s.unique_id_conflicts,

    NULL::bigint,
    NULL::bigint,
    NULL::bigint,
    NULL::bigint

FROM shared_by_combination s

ORDER BY
    result_type DESC,
    components NULLS FIRST;
