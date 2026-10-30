\set ON_ERROR_STOP on

WITH all_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        'NEW'::text AS survey_version,
        'NEW_SPOTS'::text AS source_version,
        source_row_number,
        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id,
        NULLIF(BTRIM(c0029), '') AS teaching_effectiveness,
        NULLIF(BTRIM(c0035), '') AS version_specific_rating

    FROM staging.raw_master_online_new_s02_spots_3caa2498

    UNION ALL

    SELECT
        2,
        34,
        'NEW'::text,
        'NEW_RAW'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0029), ''),
        NULLIF(BTRIM(c0035), '')

    FROM staging.raw_master_online_new_s01_rawdata_3caa2498

    UNION ALL

    SELECT
        3,
        37,
        'OLD'::text,
        'OLD_P1'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
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
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
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
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
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
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')

    FROM staging.raw_master_online_part_s01_online_6164ddea
),

valid_source_rows AS (
    SELECT
        *

    FROM all_source_rows

    WHERE response_id IS NOT NULL
      AND course_code IS NOT NULL
      AND unique_id IS NOT NULL
      AND LOWER(BTRIM(response_id)) NOT IN (
          'responseuniqueid',
          'response unique id',
          'response_id',
          'responseid'
      )
      AND LOWER(BTRIM(unique_id)) <> 'uniqueid'
),

deduplicated_responses AS (
    SELECT
        source_priority,
        component_id,
        survey_version,
        source_version,
        source_row_number,
        response_id,
        course_code,
        unique_id,
        teaching_effectiveness,
        version_specific_rating

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

normalized AS (
    SELECT
        component_id,
        survey_version,
        source_version,
        source_row_number,
        response_id,
        unique_id,

        SPLIT_PART(
            unique_id,
            '_',
            1
        ) AS term_code,

        UPPER(
            REGEXP_REPLACE(
                course_code,
                '[^A-Za-z0-9]',
                '',
                'g'
            )
        ) AS normalized_course_code,

        SPLIT_PART(
            unique_id,
            '_',
            5
        ) AS section_identifier,

        UPPER(
            REGEXP_REPLACE(
                course_code,
                '[^A-Za-z0-9]',
                '',
                'g'
            )
        )
        || '_'
        || SPLIT_PART(
            unique_id,
            '_',
            5
        ) AS candidate_source_identifier,

        CASE
            WHEN teaching_effectiveness IN ('1','2','3','4','5')
            THEN teaching_effectiveness::integer
            ELSE NULL
        END AS teaching_effectiveness_rating,

        CASE
            WHEN version_specific_rating IN ('1','2','3','4','5')
            THEN version_specific_rating::integer
            ELSE NULL
        END AS version_specific_rating

    FROM deduplicated_responses
),

classified AS (
    SELECT
        n.component_id,
        n.survey_version,
        n.source_version,
        n.source_row_number,
        n.response_id,
        n.teaching_effectiveness_rating,
        n.version_specific_rating,

        COUNT(DISTINCT t.term_id)::bigint
            AS term_matches,

        COUNT(DISTINCT c.course_id)::bigint
            AS course_matches,

        COUNT(DISTINCT o.course_offering_id)::bigint
            AS exact_offering_matches

    FROM normalized n

    LEFT JOIN core.term t
        ON BTRIM(t.term_code) = n.term_code

    LEFT JOIN core.course c
        ON UPPER(
            REGEXP_REPLACE(
                BTRIM(c.course_code),
                '[^A-Za-z0-9]',
                '',
                'g'
            )
        ) = n.normalized_course_code

    LEFT JOIN core.course_offering_section o
        ON o.term_id = t.term_id
       AND UPPER(BTRIM(o.source_identifier))
            = n.candidate_source_identifier

    GROUP BY
        n.component_id,
        n.survey_version,
        n.source_version,
        n.source_row_number,
        n.response_id,
        n.teaching_effectiveness_rating,
        n.version_specific_rating
)

SELECT
    survey_version,

    COUNT(*)::bigint AS deduplicated_responses,

    SUM(
        CASE WHEN term_matches = 1
        THEN 1 ELSE 0 END
    )::bigint AS responses_with_term_match,

    SUM(
        CASE WHEN term_matches = 0
        THEN 1 ELSE 0 END
    )::bigint AS responses_without_term_match,

    SUM(
        CASE WHEN course_matches = 1
        THEN 1 ELSE 0 END
    )::bigint AS responses_with_course_match,

    SUM(
        CASE WHEN course_matches = 0
        THEN 1 ELSE 0 END
    )::bigint AS responses_without_course_match,

    SUM(
        CASE WHEN exact_offering_matches = 1
        THEN 1 ELSE 0 END
    )::bigint AS responses_with_exact_offering_match,

    SUM(
        CASE WHEN exact_offering_matches = 0
        THEN 1 ELSE 0 END
    )::bigint AS responses_without_offering_match,

    SUM(
        CASE WHEN exact_offering_matches > 1
        THEN 1 ELSE 0 END
    )::bigint AS responses_with_ambiguous_offering_match,

    SUM(
        CASE
            WHEN exact_offering_matches = 1
             AND teaching_effectiveness_rating IS NOT NULL
            THEN 1 ELSE 0
        END
    )::bigint AS matched_teaching_responses,

    SUM(
        CASE
            WHEN exact_offering_matches = 1
             AND version_specific_rating IS NOT NULL
            THEN 1 ELSE 0
        END
    )::bigint AS matched_version_specific_responses

FROM classified

GROUP BY survey_version

ORDER BY survey_version;
