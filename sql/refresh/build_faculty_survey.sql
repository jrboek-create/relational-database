-- Builds tmp_course_faculty_survey_summary (a temporary table) using the original build logic from
-- faculty-survey-reporting-persistent-build.sql (Oct 2026), extracted unchanged. Verified on 2 Nov 2026 to reproduce
-- reporting.course_faculty_survey_summary exactly on every column except run id and as-of time.

CREATE TEMP TABLE faculty_survey_refresh_context
ON COMMIT DROP
AS
SELECT
    gen_random_uuid() AS run_id,
    CURRENT_TIMESTAMP AS report_as_of_utc;

CREATE TEMP TABLE tmp_course_faculty_survey_summary AS
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
        44,
        'NEW'::text,
        source_row_number,
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

    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0014), '') IS NOT NULL
      AND LOWER(BTRIM(c0014)) <> 'uniqueid'
),
normalized AS (
    SELECT
        component_id,
        survey_version,
        source_row_number,

        SPLIT_PART(normalized_unique_id, '_', 1)
            AS term_code,

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
),
aggregated AS (
    SELECT
        course_id,
        term_id,

        MIN(survey_version) AS survey_version,

        COUNT(*)::bigint AS faculty_response_count,

        SUM(
            CASE WHEN survey_version = 'OLD'
            THEN 1 ELSE 0 END
        )::bigint AS old_response_count,

        SUM(
            CASE WHEN survey_version = 'NEW'
            THEN 1 ELSE 0 END
        )::bigint AS new_response_count,

        SUM(
            CASE WHEN teaching_experience_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS teaching_response_count,

        ROUND(
            AVG(teaching_experience_rating),
            4
        ) AS average_teaching_experience,

        SUM(
            CASE WHEN course_quality_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS quality_response_count,

        ROUND(
            AVG(course_quality_rating),
            4
        ) AS average_course_quality

    FROM matched_responses

    GROUP BY
        course_id,
        term_id
)
SELECT
    a.course_id,
    a.term_id,
    t.term_code,
    t.term_label,
    d.university_course_id,
    d.course_code,
    d.course_title,
    d.college_name,
    d.department_name,
    a.survey_version,
    a.faculty_response_count,
    a.old_response_count,
    a.new_response_count,
    a.teaching_response_count,
    a.average_teaching_experience,
    a.quality_response_count,
    a.average_course_quality,

    ctx.run_id AS report_refresh_run_id,
    ctx.report_as_of_utc,

    MD5(
        CONCAT_WS(
            '|',
            a.course_id::text,
            a.term_id::text,
            t.term_code,
            COALESCE(t.term_label, ''),
            d.university_course_id,
            d.course_code,
            d.course_title,
            d.college_name,
            d.department_name,
            a.survey_version,
            a.faculty_response_count::text,
            a.old_response_count::text,
            a.new_response_count::text,
            a.teaching_response_count::text,
            COALESCE(a.average_teaching_experience::text, ''),
            a.quality_response_count::text,
            COALESCE(a.average_course_quality::text, '')
        )
    ) AS business_row_hash

FROM aggregated a

JOIN core.term t
    ON t.term_id = a.term_id

JOIN reporting.course_catalog_detail d
    ON d.course_id = a.course_id

CROSS JOIN faculty_survey_refresh_context ctx;
