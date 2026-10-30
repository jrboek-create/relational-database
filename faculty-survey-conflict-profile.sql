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
        NULLIF(BTRIM(c0021), '') AS submit_date,
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
        NULLIF(BTRIM(c0021), ''),
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
        submit_date,
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
),
matched AS (
    SELECT
        n.component_id,
        n.survey_version,
        n.response_unique_id,
        n.normalized_unique_id,
        n.submit_date,
        n.teaching_experience_rating,
        n.course_quality_rating,
        o.course_offering_id
    FROM normalized n
    JOIN core.term t
        ON BTRIM(t.term_code) = n.term_code
    JOIN core.course_offering_section o
        ON o.term_id = t.term_id
       AND UPPER(BTRIM(o.source_identifier))
            = n.candidate_source_identifier
),
conflicting_ids AS (
    SELECT
        component_id,
        normalized_unique_id
    FROM matched
    GROUP BY
        component_id,
        normalized_unique_id
    HAVING
        COUNT(DISTINCT response_unique_id) > 1
        OR COUNT(DISTINCT course_offering_id) > 1
        OR COUNT(DISTINCT teaching_experience_rating) > 1
        OR COUNT(DISTINCT course_quality_rating) > 1
)
SELECT
    m.component_id,
    m.survey_version,
    m.normalized_unique_id,
    m.course_offering_id,
    m.response_unique_id,
    m.teaching_experience_rating,
    m.course_quality_rating,
    m.submit_date,
    COUNT(*) AS repeated_rows
FROM matched m
JOIN conflicting_ids c
    ON c.component_id = m.component_id
   AND c.normalized_unique_id = m.normalized_unique_id
GROUP BY
    m.component_id,
    m.survey_version,
    m.normalized_unique_id,
    m.course_offering_id,
    m.response_unique_id,
    m.teaching_experience_rating,
    m.course_quality_rating,
    m.submit_date
ORDER BY
    m.component_id,
    m.normalized_unique_id,
    m.submit_date,
    m.response_unique_id;
