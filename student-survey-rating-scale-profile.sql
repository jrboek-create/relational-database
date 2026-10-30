\set ON_ERROR_STOP on

WITH all_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        'NEW'::text AS survey_version,
        'NEW_SPOTS'::text AS source_version,
        source_row_number,
        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0029), '') AS teaching_effectiveness,
        NULLIF(BTRIM(c0035), '') AS course_recommendation,
        NULL::text AS course_quality

    FROM staging.raw_master_online_new_s02_spots_3caa2498

    UNION ALL

    SELECT
        2,
        34,
        'NEW'::text,
        'NEW_RAW'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0029), ''),
        NULLIF(BTRIM(c0035), ''),
        NULL::text

    FROM staging.raw_master_online_new_s01_rawdata_3caa2498

    UNION ALL

    SELECT
        3,
        37,
        'OLD'::text,
        'OLD_P1'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0048), ''),
        NULL::text,
        NULLIF(BTRIM(c0050), '')

    FROM staging.raw_master_online_part_s01_online_31fb6e24

    UNION ALL

    SELECT
        4,
        40,
        'OLD'::text,
        'OLD_P2'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0048), ''),
        NULL::text,
        NULLIF(BTRIM(c0050), '')

    FROM staging.raw_master_online_part_s01_online_3417e822

    UNION ALL

    SELECT
        5,
        41,
        'OLD'::text,
        'OLD_P3'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0048), ''),
        NULL::text,
        NULLIF(BTRIM(c0050), '')

    FROM staging.raw_master_online_part_s01_online_324dd997

    UNION ALL

    SELECT
        6,
        42,
        'OLD'::text,
        'OLD_P4'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0048), ''),
        NULL::text,
        NULLIF(BTRIM(c0050), '')

    FROM staging.raw_master_online_part_s01_online_6164ddea
),

valid_source_rows AS (
    SELECT
        source_priority,
        component_id,
        survey_version,
        source_version,
        source_row_number,
        response_id,
        teaching_effectiveness,
        course_recommendation,
        course_quality

    FROM all_source_rows

    WHERE response_id IS NOT NULL
      AND LOWER(BTRIM(response_id)) NOT IN (
          'responseuniqueid',
          'response unique id',
          'response_id',
          'responseid'
      )
),

deduplicated_responses AS (
    SELECT
        source_priority,
        component_id,
        survey_version,
        source_version,
        source_row_number,
        response_id,
        teaching_effectiveness,
        course_recommendation,
        course_quality

    FROM (
        SELECT
            v.*,

            ROW_NUMBER() OVER (
                PARTITION BY response_id
                ORDER BY
                    source_priority,
                    component_id,
                    source_row_number
            ) AS response_rank

        FROM valid_source_rows v
    ) ranked

    WHERE response_rank = 1
),

metrics AS (
    SELECT
        survey_version,
        'teaching_effectiveness'::text AS metric,
        CASE
            WHEN survey_version = 'OLD'
            THEN 'Question 26'
            ELSE 'Question 7'
        END AS source_question,
        teaching_effectiveness AS raw_value

    FROM deduplicated_responses

    UNION ALL

    SELECT
        survey_version,
        'course_quality'::text,
        'Question 28',
        course_quality

    FROM deduplicated_responses

    WHERE survey_version = 'OLD'

    UNION ALL

    SELECT
        survey_version,
        'course_recommendation'::text,
        'Question 13',
        course_recommendation

    FROM deduplicated_responses

    WHERE survey_version = 'NEW'
),

classified_metrics AS (
    SELECT
        survey_version,
        metric,
        source_question,
        raw_value,

        CASE
            WHEN raw_value IN ('1', '2', '3', '4', '5')
            THEN raw_value::numeric
            ELSE NULL
        END AS numeric_rating

    FROM metrics
)

SELECT
    survey_version,
    metric,
    source_question,

    COUNT(*)::bigint AS response_rows,

    SUM(
        CASE
            WHEN raw_value IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint AS populated_rows,

    SUM(
        CASE
            WHEN numeric_rating IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint AS valid_numeric_rows,

    SUM(
        CASE
            WHEN raw_value IS NOT NULL
             AND numeric_rating IS NULL
            THEN 1
            ELSE 0
        END
    )::bigint AS nonnumeric_or_out_of_range_rows,

    MIN(numeric_rating) AS minimum_rating,
    MAX(numeric_rating) AS maximum_rating,

    ROUND(
        AVG(numeric_rating),
        4
    ) AS average_rating,

    COUNT(
        DISTINCT numeric_rating
    )::bigint AS distinct_numeric_values

FROM classified_metrics

GROUP BY
    survey_version,
    metric,
    source_question

ORDER BY
    metric,
    survey_version;
