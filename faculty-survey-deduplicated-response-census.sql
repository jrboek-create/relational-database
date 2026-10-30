\set ON_ERROR_STOP on

WITH faculty_sources AS (
    SELECT
        16 AS component_id,
        'OLD'::text AS survey_version,
        NULLIF(BTRIM(c0001), '') AS response_unique_id,
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
    WHERE NULLIF(BTRIM(c0014), '') IS NOT NULL
      AND LOWER(BTRIM(c0014)) <> 'uniqueid'

    UNION ALL

    SELECT
        44,
        'NEW'::text,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        CASE
            WHEN BTRIM(c0014) ~ '^[^_]+_FCF_'
            THEN REGEXP_REPLACE(
                BTRIM(c0014),
                '^([^_]+)_FCF_',
                E'\\1_'
            )
            ELSE BTRIM(c0014)
        END,
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0049), '')
    FROM staging.raw_new_master_faculty_s02_feots_new_18832c28
    WHERE NULLIF(BTRIM(c0014), '') IS NOT NULL
      AND LOWER(BTRIM(c0014)) <> 'uniqueid'
),
normalized AS (
    SELECT
        component_id,
        survey_version,
        response_unique_id,
        normalized_unique_id,
        SPLIT_PART(normalized_unique_id, '_', 1) AS term_code,
        UPPER(
            REGEXP_REPLACE(
                course_code,
                '[^A-Za-z0-9]',
                '',
                'g'
            )
        )
        || '_'
        || SPLIT_PART(normalized_unique_id, '_', 5)
            AS candidate_source_identifier,
        CASE
            WHEN teaching_experience IN ('1','2','3','4','5')
            THEN teaching_experience::integer
            ELSE NULL
        END AS teaching_experience_rating,
        CASE
            WHEN course_quality IN ('1','2','3','4','5')
            THEN course_quality::integer
            ELSE NULL
        END AS course_quality_rating
    FROM faculty_sources
    WHERE response_unique_id IS NOT NULL
),
matched AS (
    SELECT
        n.component_id,
        n.survey_version,
        n.response_unique_id,
        n.normalized_unique_id,
        n.teaching_experience_rating,
        n.course_quality_rating,
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
response_profile AS (
    SELECT
        component_id,
        survey_version,
        response_unique_id,
        COUNT(*) AS source_rows,
        COUNT(DISTINCT normalized_unique_id) AS section_count,
        COUNT(DISTINCT course_offering_id) AS offering_count,
        COUNT(DISTINCT teaching_experience_rating)
            AS teaching_value_count,
        COUNT(DISTINCT course_quality_rating)
            AS quality_value_count,
        MIN(course_id) AS course_id,
        MIN(term_id) AS term_id,
        MIN(teaching_experience_rating)
            AS teaching_experience_rating,
        MIN(course_quality_rating)
            AS course_quality_rating
    FROM matched
    GROUP BY
        component_id,
        survey_version,
        response_unique_id
),
eligible AS (
    SELECT *
    FROM response_profile
    WHERE section_count = 1
      AND offering_count = 1
      AND teaching_value_count <= 1
      AND quality_value_count <= 1
)
SELECT
    component_id,
    survey_version,
    COUNT(*) AS distinct_matched_responses,
    SUM(source_rows) AS represented_source_rows,
    SUM(source_rows - 1) AS duplicate_source_rows_removed,
    COUNT(DISTINCT course_id) AS represented_courses,
    COUNT(DISTINCT term_id) AS represented_terms,
    COUNT(
        DISTINCT course_id::text || ':' || term_id::text
    ) AS course_term_groups,
    SUM(
        CASE
            WHEN teaching_experience_rating IS NOT NULL
            THEN 1 ELSE 0
        END
    ) AS teaching_response_count,
    ROUND(
        AVG(teaching_experience_rating),
        4
    ) AS average_teaching_experience,
    SUM(
        CASE
            WHEN course_quality_rating IS NOT NULL
            THEN 1 ELSE 0
        END
    ) AS quality_response_count,
    ROUND(
        AVG(course_quality_rating),
        4
    ) AS average_course_quality
FROM eligible
GROUP BY
    component_id,
    survey_version
ORDER BY component_id;
