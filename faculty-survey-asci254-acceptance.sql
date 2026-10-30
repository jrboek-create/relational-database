\set ON_ERROR_STOP on

WITH faculty_sources AS (
    SELECT
        16 AS component_id,
        'OLD'::text AS survey_version,
        source_row_number,
        NULLIF(BTRIM(c0012), '') AS course_code,

        CASE
            WHEN BTRIM(c0014) ~ '^[^_]+_FCF_'
            THEN REGEXP_REPLACE(
                BTRIM(c0014),
                '^([^_]+)_FCF_',
                E'\\1_'
            )
            ELSE BTRIM(c0014)
        END AS normalized_unique_id,

        NULLIF(BTRIM(c0023), '') AS teaching_experience,
        NULLIF(BTRIM(c0038), '') AS course_quality

    FROM staging.raw_master_facultycour_s01_feots_e4a0bf70

    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0014), '') IS NOT NULL
      AND LOWER(BTRIM(c0014)) <> 'uniqueid'

    UNION ALL

    SELECT
        44 AS component_id,
        'NEW'::text AS survey_version,
        source_row_number,
        NULLIF(BTRIM(c0012), '') AS course_code,

        CASE
            WHEN BTRIM(c0014) ~ '^[^_]+_FCF_'
            THEN REGEXP_REPLACE(
                BTRIM(c0014),
                '^([^_]+)_FCF_',
                E'\\1_'
            )
            ELSE BTRIM(c0014)
        END AS normalized_unique_id,

        NULLIF(BTRIM(c0048), '') AS teaching_experience,
        NULLIF(BTRIM(c0049), '') AS course_quality

    FROM staging.raw_new_master_faculty_s02_feots_new_18832c28

    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0014), '') IS NOT NULL
      AND LOWER(BTRIM(c0014)) <> 'uniqueid'
),

normalized AS (
    SELECT
        component_id,
        survey_version,
        source_row_number,
        normalized_unique_id,

        SPLIT_PART(
            normalized_unique_id,
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
        )
        || '_'
        || SPLIT_PART(
            normalized_unique_id,
            '_',
            5
        ) AS candidate_source_identifier,

        CASE
            WHEN teaching_experience IN ('1', '2', '3', '4', '5')
            THEN teaching_experience::integer
            ELSE NULL
        END AS teaching_experience_rating,

        CASE
            WHEN course_quality IN ('1', '2', '3', '4', '5')
            THEN course_quality::integer
            ELSE NULL
        END AS course_quality_rating

    FROM faculty_sources

    WHERE normalized_unique_id IS NOT NULL
      AND course_code IS NOT NULL
),

matched_responses AS (
    SELECT
        n.component_id,
        n.survey_version,
        n.source_row_number,
        n.teaching_experience_rating,
        n.course_quality_rating,
        t.term_id,
        o.course_id

    FROM normalized n

    JOIN core.term t
        ON BTRIM(t.term_code) = n.term_code

    JOIN core.course_offering_section o
        ON o.term_id = t.term_id
       AND UPPER(BTRIM(o.source_identifier))
            = n.candidate_source_identifier
)

SELECT
    t.term_code,
    t.term_label,

    MIN(m.survey_version) AS survey_version,

    COUNT(*)::bigint AS faculty_response_count,

    SUM(
        CASE
            WHEN m.teaching_experience_rating IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint AS teaching_response_count,

    ROUND(
        AVG(m.teaching_experience_rating),
        2
    ) AS average_teaching_experience,

    SUM(
        CASE
            WHEN m.course_quality_rating IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint AS quality_response_count,

    ROUND(
        AVG(m.course_quality_rating),
        2
    ) AS average_course_quality

FROM matched_responses m

JOIN core.term t
    ON t.term_id = m.term_id

WHERE m.course_id =
    '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid

GROUP BY
    t.term_id,
    t.term_code,
    t.term_label

ORDER BY
    CASE
        WHEN t.term_code ~ '^[0-9]+$'
        THEN t.term_code::integer
        ELSE NULL
    END DESC,
    t.term_code DESC;
