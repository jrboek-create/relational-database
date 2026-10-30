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
        44 AS component_id,
        'NEW'::text AS survey_version,
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
        NULLIF(BTRIM(c0048), '') AS teaching_experience,
        NULLIF(BTRIM(c0049), '') AS course_quality
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
            WHEN teaching_experience IN ('1', '2', '3', '4', '5')
            THEN teaching_experience::numeric
            ELSE NULL
        END AS teaching_experience_rating,
        CASE
            WHEN course_quality IN ('1', '2', '3', '4', '5')
            THEN course_quality::numeric
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
        n.teaching_experience_rating,
        n.course_quality_rating,
        t.term_id,
        o.course_offering_id,
        o.course_id
    FROM normalized n
    JOIN core.term t
        ON BTRIM(t.term_code) = n.term_code
    JOIN core.course_offering_section o
        ON o.term_id = t.term_id
       AND UPPER(BTRIM(o.source_identifier))
            = n.candidate_source_identifier
),
matched_summary AS (
    SELECT
        component_id,
        survey_version,
        COUNT(*) AS matched_rows,
        COUNT(DISTINCT normalized_unique_id)
            AS matched_normalized_ids,
        COUNT(DISTINCT response_unique_id)
            AS matched_response_ids,
        COUNT(DISTINCT course_offering_id)
            AS matched_offerings,
        COUNT(
            DISTINCT course_id::text || ':' || term_id::text
        ) AS matched_course_term_groups,
        SUM(
            CASE
                WHEN teaching_experience_rating IS NOT NULL
                THEN 1
                ELSE 0
            END
        ) AS valid_teaching_rating_rows,
        SUM(
            CASE
                WHEN course_quality_rating IS NOT NULL
                THEN 1
                ELSE 0
            END
        ) AS valid_quality_rating_rows
    FROM matched
    GROUP BY
        component_id,
        survey_version
),
normalized_id_profile AS (
    SELECT
        component_id,
        normalized_unique_id,
        COUNT(*) AS source_rows,
        COUNT(DISTINCT response_unique_id)
            AS response_id_count,
        COUNT(DISTINCT course_offering_id)
            AS offering_count,
        COUNT(DISTINCT teaching_experience_rating)
            AS teaching_value_count,
        COUNT(DISTINCT course_quality_rating)
            AS quality_value_count
    FROM matched
    GROUP BY
        component_id,
        normalized_unique_id
),
normalized_diagnostics AS (
    SELECT
        component_id,
        SUM(
            CASE
                WHEN source_rows > 1
                THEN 1
                ELSE 0
            END
        ) AS normalized_ids_with_multiple_rows,
        SUM(
            CASE
                WHEN response_id_count > 1
                  OR offering_count > 1
                  OR teaching_value_count > 1
                  OR quality_value_count > 1
                THEN 1
                ELSE 0
            END
        ) AS conflicting_normalized_ids
    FROM normalized_id_profile
    GROUP BY component_id
),
response_id_profile AS (
    SELECT
        component_id,
        response_unique_id,
        COUNT(*) AS source_rows,
        COUNT(DISTINCT normalized_unique_id)
            AS normalized_id_count,
        COUNT(DISTINCT course_offering_id)
            AS offering_count,
        COUNT(DISTINCT teaching_experience_rating)
            AS teaching_value_count,
        COUNT(DISTINCT course_quality_rating)
            AS quality_value_count
    FROM matched
    WHERE response_unique_id IS NOT NULL
    GROUP BY
        component_id,
        response_unique_id
),
response_diagnostics AS (
    SELECT
        component_id,
        SUM(
            CASE
                WHEN normalized_id_count > 1
                THEN 1
                ELSE 0
            END
        ) AS response_ids_linked_to_multiple_normalized_ids,
        SUM(
            CASE
                WHEN offering_count > 1
                  OR teaching_value_count > 1
                  OR quality_value_count > 1
                THEN 1
                ELSE 0
            END
        ) AS conflicting_response_ids
    FROM response_id_profile
    GROUP BY component_id
)
SELECT
    s.component_id,
    s.survey_version,
    s.matched_rows,
    s.matched_normalized_ids,
    s.matched_response_ids,
    s.matched_offerings,
    s.matched_course_term_groups,
    s.valid_teaching_rating_rows,
    s.valid_quality_rating_rows,
    COALESCE(
        n.normalized_ids_with_multiple_rows,
        0
    ) AS normalized_ids_with_multiple_rows,
    COALESCE(
        n.conflicting_normalized_ids,
        0
    ) AS conflicting_normalized_ids,
    COALESCE(
        r.response_ids_linked_to_multiple_normalized_ids,
        0
    ) AS response_ids_linked_to_multiple_normalized_ids,
    COALESCE(
        r.conflicting_response_ids,
        0
    ) AS conflicting_response_ids
FROM matched_summary s
LEFT JOIN normalized_diagnostics n
    ON n.component_id = s.component_id
LEFT JOIN response_diagnostics r
    ON r.component_id = s.component_id
ORDER BY s.component_id;
