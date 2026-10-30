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

    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0014), '') IS NOT NULL
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

    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0014), '') IS NOT NULL
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

    WHERE normalized_unique_id IS NOT NULL
      AND course_code IS NOT NULL
),

matched_responses AS (
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

course_term_summary AS (
    SELECT
        course_id,
        term_id,

        COUNT(*)::bigint
            AS faculty_response_count,

        SUM(
            CASE
                WHEN survey_version = 'OLD'
                THEN 1
                ELSE 0
            END
        )::bigint AS old_response_count,

        SUM(
            CASE
                WHEN survey_version = 'NEW'
                THEN 1
                ELSE 0
            END
        )::bigint AS new_response_count,

        SUM(
            CASE
                WHEN teaching_experience_rating IS NOT NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS teaching_response_count,

        ROUND(
            AVG(teaching_experience_rating),
            4
        ) AS average_teaching_experience,

        SUM(
            CASE
                WHEN course_quality_rating IS NOT NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS quality_response_count,

        ROUND(
            AVG(course_quality_rating),
            4
        ) AS average_course_quality

    FROM matched_responses

    GROUP BY
        course_id,
        term_id
),

global_summary AS (
    SELECT
        COUNT(*)::bigint
            AS faculty_course_term_rows,

        COUNT(DISTINCT course_id)::bigint
            AS represented_courses,

        COUNT(DISTINCT term_id)::bigint
            AS represented_terms,

        SUM(faculty_response_count)::bigint
            AS total_faculty_responses,

        SUM(old_response_count)::bigint
            AS old_response_count,

        SUM(new_response_count)::bigint
            AS new_response_count,

        SUM(teaching_response_count)::bigint
            AS teaching_response_count,

        ROUND(
            SUM(
                average_teaching_experience
                * teaching_response_count
            )
            / NULLIF(
                SUM(teaching_response_count),
                0
            ),
            4
        ) AS weighted_average_teaching_experience,

        SUM(quality_response_count)::bigint
            AS quality_response_count,

        ROUND(
            SUM(
                average_course_quality
                * quality_response_count
            )
            / NULLIF(
                SUM(quality_response_count),
                0
            ),
            4
        ) AS weighted_average_course_quality,

        MIN(faculty_response_count)::bigint
            AS minimum_responses_per_course_term,

        MAX(faculty_response_count)::bigint
            AS maximum_responses_per_course_term,

        SUM(
            CASE
                WHEN old_response_count > 0
                 AND new_response_count > 0
                THEN 1
                ELSE 0
            END
        )::bigint
            AS course_terms_with_both_versions

    FROM course_term_summary
)

SELECT
    faculty_course_term_rows,
    represented_courses,
    represented_terms,
    total_faculty_responses,
    old_response_count,
    new_response_count,
    teaching_response_count,
    weighted_average_teaching_experience,
    quality_response_count,
    weighted_average_course_quality,
    minimum_responses_per_course_term,
    maximum_responses_per_course_term,
    course_terms_with_both_versions

FROM global_summary;
