\set ON_ERROR_STOP on

WITH faculty_sources AS (
    SELECT
        16 AS component_id,
        'OLD'::text AS survey_version,
        source_row_number,
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
        source_row_number,
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
        source_row_number,
        response_unique_id,
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

    WHERE source_row_number IS NOT NULL
      AND normalized_unique_id IS NOT NULL
      AND course_code IS NOT NULL
),

matched AS (
    SELECT
        n.component_id,
        n.survey_version,
        n.source_row_number,
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

source_row_profile AS (
    SELECT
        component_id,
        survey_version,
        source_row_number,

        COUNT(*)::bigint AS matched_join_rows,

        COUNT(DISTINCT course_id)::bigint
            AS course_count,

        COUNT(DISTINCT term_id)::bigint
            AS term_count,

        COUNT(DISTINCT course_offering_id)::bigint
            AS offering_count,

        COUNT(DISTINCT normalized_unique_id)::bigint
            AS normalized_id_count,

        COUNT(DISTINCT teaching_experience_rating)::bigint
            AS teaching_value_count,

        COUNT(DISTINCT course_quality_rating)::bigint
            AS quality_value_count

    FROM matched

    GROUP BY
        component_id,
        survey_version,
        source_row_number
),

version_summary AS (
    SELECT
        m.component_id,
        m.survey_version,

        COUNT(*)::bigint AS matched_source_rows,

        COUNT(
            DISTINCT m.source_row_number
        )::bigint AS distinct_source_rows,

        COUNT(
            DISTINCT m.response_unique_id
        )::bigint AS distinct_response_ids,

        SUM(
            CASE
                WHEN m.response_unique_id IS NOT NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS rows_with_response_id,

        SUM(
            CASE
                WHEN m.response_unique_id IS NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS rows_without_response_id,

        COUNT(
            DISTINCT m.normalized_unique_id
        )::bigint AS represented_section_ids,

        COUNT(
            DISTINCT m.course_offering_id
        )::bigint AS represented_offerings,

        COUNT(
            DISTINCT m.course_id
        )::bigint AS represented_courses,

        COUNT(
            DISTINCT m.term_id
        )::bigint AS represented_terms,

        COUNT(
            DISTINCT m.course_id::text || ':' || m.term_id::text
        )::bigint AS course_term_groups,

        SUM(
            CASE
                WHEN m.teaching_experience_rating IS NOT NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS teaching_response_count,

        ROUND(
            AVG(m.teaching_experience_rating),
            4
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
            4
        ) AS average_course_quality

    FROM matched m

    GROUP BY
        m.component_id,
        m.survey_version
),

source_row_diagnostics AS (
    SELECT
        component_id,

        SUM(
            CASE
                WHEN matched_join_rows > 1
                THEN 1
                ELSE 0
            END
        )::bigint AS source_rows_with_multiple_join_matches,

        SUM(
            CASE
                WHEN course_count > 1
                  OR term_count > 1
                  OR offering_count > 1
                  OR normalized_id_count > 1
                  OR teaching_value_count > 1
                  OR quality_value_count > 1
                THEN 1
                ELSE 0
            END
        )::bigint AS conflicting_source_rows

    FROM source_row_profile

    GROUP BY component_id
)

SELECT
    s.component_id,
    s.survey_version,
    s.matched_source_rows,
    s.distinct_source_rows,
    s.distinct_response_ids,
    s.rows_with_response_id,
    s.rows_without_response_id,
    s.represented_section_ids,
    s.represented_offerings,
    s.represented_courses,
    s.represented_terms,
    s.course_term_groups,
    s.teaching_response_count,
    s.average_teaching_experience,
    s.quality_response_count,
    s.average_course_quality,
    d.source_rows_with_multiple_join_matches,
    d.conflicting_source_rows

FROM version_summary s

JOIN source_row_diagnostics d
    ON d.component_id = s.component_id

ORDER BY s.component_id;
