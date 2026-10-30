\set ON_ERROR_STOP on

WITH all_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        'NEW'::text AS survey_version,
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
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_6164ddea
),

valid_source_rows AS (
    SELECT *
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
        component_id,
        survey_version,
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
        source_row_number,
        response_id,

        SPLIT_PART(unique_id, '_', 1) AS term_code,

        UPPER(
            REGEXP_REPLACE(
                course_code,
                '[^A-Za-z0-9]',
                '',
                'g'
            )
        )
        || '_'
        || SPLIT_PART(unique_id, '_', 5)
            AS candidate_source_identifier,

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

matched_responses AS (
    SELECT
        n.component_id,
        n.survey_version,
        n.source_row_number,
        n.response_id,
        n.teaching_effectiveness_rating,

        CASE
            WHEN n.survey_version = 'OLD'
            THEN n.version_specific_rating
            ELSE NULL
        END AS course_quality_rating,

        CASE
            WHEN n.survey_version = 'NEW'
            THEN n.version_specific_rating
            ELSE NULL
        END AS course_recommendation_rating,

        t.term_id,
        o.course_id,
        o.course_offering_id

    FROM normalized n

    JOIN core.term t
        ON BTRIM(t.term_code) = n.term_code

    JOIN core.course_offering_section o
        ON o.term_id = t.term_id
       AND UPPER(BTRIM(o.source_identifier))
            = n.candidate_source_identifier
),

course_term_summary AS (
    SELECT
        course_id,
        term_id,

        COUNT(*)::bigint AS student_response_count,

        SUM(
            CASE WHEN survey_version = 'OLD'
            THEN 1 ELSE 0 END
        )::bigint AS old_response_count,

        SUM(
            CASE WHEN survey_version = 'NEW'
            THEN 1 ELSE 0 END
        )::bigint AS new_response_count,

        SUM(
            CASE WHEN teaching_effectiveness_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS teaching_response_count,

        ROUND(
            AVG(teaching_effectiveness_rating),
            4
        ) AS average_teaching_effectiveness,

        SUM(
            CASE WHEN course_quality_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS course_quality_response_count,

        ROUND(
            AVG(course_quality_rating),
            4
        ) AS average_course_quality,

        SUM(
            CASE WHEN course_recommendation_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS course_recommendation_response_count,

        ROUND(
            AVG(course_recommendation_rating),
            4
        ) AS average_course_recommendation

    FROM matched_responses

    GROUP BY
        course_id,
        term_id
)

SELECT
    t.term_code,
    t.term_label,

    CASE
        WHEN s.old_response_count > 0
        THEN 'OLD'
        WHEN s.new_response_count > 0
        THEN 'NEW'
        ELSE NULL
    END AS survey_version,

    s.student_response_count,
    s.teaching_response_count,
    s.average_teaching_effectiveness,

    s.course_quality_response_count,
    s.average_course_quality,

    s.course_recommendation_response_count,
    s.average_course_recommendation

FROM course_term_summary s

JOIN core.term t
    ON t.term_id = s.term_id

WHERE s.course_id =
    '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid

ORDER BY
    CASE
        WHEN t.term_code ~ '^[0-9]+$'
        THEN t.term_code::integer
        ELSE NULL
    END DESC,
    t.term_code DESC;