\set ON_ERROR_STOP on

BEGIN;

CREATE TABLE reporting.course_faculty_survey_summary AS
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
),

aggregated AS (
    SELECT
        course_id,
        term_id,

        MIN(survey_version) AS survey_version,

        COUNT(*)::bigint AS faculty_response_count,

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
    a.average_course_quality

FROM aggregated a

JOIN core.term t
    ON t.term_id = a.term_id

JOIN reporting.course_catalog_detail d
    ON d.course_id = a.course_id;

ALTER TABLE reporting.course_faculty_survey_summary
    ALTER COLUMN course_id SET NOT NULL,
    ALTER COLUMN term_id SET NOT NULL,
    ALTER COLUMN term_code SET NOT NULL,
    ALTER COLUMN course_code SET NOT NULL,
    ALTER COLUMN course_title SET NOT NULL,
    ALTER COLUMN college_name SET NOT NULL,
    ALTER COLUMN department_name SET NOT NULL,
    ALTER COLUMN survey_version SET NOT NULL,
    ALTER COLUMN faculty_response_count SET NOT NULL,
    ALTER COLUMN old_response_count SET NOT NULL,
    ALTER COLUMN new_response_count SET NOT NULL,
    ALTER COLUMN teaching_response_count SET NOT NULL,
    ALTER COLUMN quality_response_count SET NOT NULL;

ALTER TABLE reporting.course_faculty_survey_summary
    ADD CONSTRAINT course_faculty_survey_summary_pkey
    PRIMARY KEY (course_id, term_id);

ALTER TABLE reporting.course_faculty_survey_summary
    ADD CONSTRAINT ck_course_faculty_survey_summary_counts
    CHECK (
        faculty_response_count > 0
        AND old_response_count >= 0
        AND new_response_count >= 0
        AND faculty_response_count =
            old_response_count + new_response_count
        AND teaching_response_count >= 0
        AND teaching_response_count <= faculty_response_count
        AND quality_response_count >= 0
        AND quality_response_count <= faculty_response_count
        AND (
            average_teaching_experience IS NULL
            OR average_teaching_experience BETWEEN 1 AND 5
        )
        AND (
            average_course_quality IS NULL
            OR average_course_quality BETWEEN 1 AND 5
        )
        AND survey_version IN ('OLD', 'NEW')
        AND NOT (
            old_response_count > 0
            AND new_response_count > 0
        )
    );

CREATE INDEX course_faculty_survey_summary_course_code_idx
    ON reporting.course_faculty_survey_summary (course_code);

CREATE INDEX course_faculty_survey_summary_term_code_idx
    ON reporting.course_faculty_survey_summary (term_code);

CREATE TABLE reporting.course_faculty_survey_summary_api AS
SELECT
    course_id,
    term_id,
    term_code,
    term_label,
    university_course_id,
    course_code,
    course_title,
    college_name,
    department_name,
    survey_version,
    faculty_response_count,
    old_response_count,
    new_response_count,
    teaching_response_count,
    average_teaching_experience,
    quality_response_count,
    average_course_quality,
    MD5(course_id::text || ':' || term_id::text)::uuid
        AS faculty_survey_summary_id

FROM reporting.course_faculty_survey_summary;

ALTER TABLE reporting.course_faculty_survey_summary_api
    ALTER COLUMN faculty_survey_summary_id SET NOT NULL;

ALTER TABLE reporting.course_faculty_survey_summary_api
    ADD CONSTRAINT course_faculty_survey_summary_api_pkey
    PRIMARY KEY (faculty_survey_summary_id);

ALTER TABLE reporting.course_faculty_survey_summary_api
    ADD CONSTRAINT course_faculty_survey_summary_api_course_term_key
    UNIQUE (course_id, term_id);

CREATE INDEX course_faculty_survey_summary_api_course_code_idx
    ON reporting.course_faculty_survey_summary_api (course_code);

CREATE INDEX course_faculty_survey_summary_api_term_code_idx
    ON reporting.course_faculty_survey_summary_api (term_code);

SELECT
    COUNT(*) AS summary_rows,
    COUNT(DISTINCT course_id) AS represented_courses,
    COUNT(DISTINCT term_id) AS represented_terms,
    SUM(faculty_response_count) AS total_faculty_responses,
    SUM(old_response_count) AS old_response_count,
    SUM(new_response_count) AS new_response_count,
    SUM(teaching_response_count) AS teaching_response_count,

    ROUND(
        SUM(
            average_teaching_experience
            * teaching_response_count
        )
        / NULLIF(SUM(teaching_response_count), 0),
        4
    ) AS weighted_average_teaching_experience,

    SUM(quality_response_count) AS quality_response_count,

    ROUND(
        SUM(
            average_course_quality
            * quality_response_count
        )
        / NULLIF(SUM(quality_response_count), 0),
        4
    ) AS weighted_average_course_quality,

    COUNT(*) FILTER (
        WHERE old_response_count > 0
          AND new_response_count > 0
    ) AS mixed_version_rows,

    COUNT(*) FILTER (
        WHERE faculty_response_count <>
            old_response_count + new_response_count
    ) AS invalid_response_count_rows

FROM reporting.course_faculty_survey_summary;

SELECT
    COUNT(*) AS api_rows,
    COUNT(DISTINCT faculty_survey_summary_id)
        AS unique_api_ids,
    COUNT(
        DISTINCT course_id::text || ':' || term_id::text
    ) AS unique_business_keys

FROM reporting.course_faculty_survey_summary_api;

SELECT
    term_code,
    term_label,
    survey_version,
    faculty_response_count,
    teaching_response_count,
    average_teaching_experience,
    quality_response_count,
    average_course_quality

FROM reporting.course_faculty_survey_summary

WHERE course_id =
    '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid

ORDER BY
    CASE
        WHEN term_code ~ '^[0-9]+$'
        THEN term_code::integer
        ELSE NULL
    END DESC,
    term_code DESC

LIMIT 5;

SELECT
    COUNT(*) AS tables_visible_inside_transaction

FROM information_schema.tables

WHERE table_schema = 'reporting'
  AND table_name IN (
      'course_faculty_survey_summary',
      'course_faculty_survey_summary_api'
  );

ROLLBACK;

SELECT
    COUNT(*) AS tables_after_rollback

FROM information_schema.tables

WHERE table_schema = 'reporting'
  AND table_name IN (
      'course_faculty_survey_summary',
      'course_faculty_survey_summary_api'
  );
