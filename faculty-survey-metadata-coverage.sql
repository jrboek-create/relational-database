\set ON_ERROR_STOP on

WITH faculty_sources AS (
    SELECT
        16 AS component_id,
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
        END AS normalized_unique_id

    FROM staging.raw_master_facultycour_s01_feots_e4a0bf70

    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0014), '') IS NOT NULL
      AND LOWER(BTRIM(c0014)) <> 'uniqueid'

    UNION ALL

    SELECT
        44,
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
        END

    FROM staging.raw_new_master_faculty_s02_feots_new_18832c28

    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0014), '') IS NOT NULL
      AND LOWER(BTRIM(c0014)) <> 'uniqueid'
),

normalized AS (
    SELECT
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
        ) AS candidate_source_identifier

    FROM faculty_sources

    WHERE normalized_unique_id IS NOT NULL
      AND course_code IS NOT NULL
),

represented_courses AS (
    SELECT DISTINCT
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
    COUNT(*) AS represented_courses,

    COUNT(*) FILTER (
        WHERE d.course_id IS NOT NULL
    ) AS courses_with_catalog_detail,

    COUNT(*) FILTER (
        WHERE d.course_id IS NULL
    ) AS courses_without_catalog_detail,

    COUNT(*) FILTER (
        WHERE NULLIF(BTRIM(d.university_course_id), '') IS NOT NULL
    ) AS courses_with_university_course_id,

    COUNT(*) FILTER (
        WHERE NULLIF(BTRIM(d.course_code), '') IS NOT NULL
    ) AS courses_with_course_code,

    COUNT(*) FILTER (
        WHERE NULLIF(BTRIM(d.course_title), '') IS NOT NULL
    ) AS courses_with_course_title,

    COUNT(*) FILTER (
        WHERE NULLIF(BTRIM(d.college_name), '') IS NOT NULL
    ) AS courses_with_college,

    COUNT(*) FILTER (
        WHERE NULLIF(BTRIM(d.department_name), '') IS NOT NULL
    ) AS courses_with_department

FROM represented_courses r

LEFT JOIN reporting.course_catalog_detail d
    ON d.course_id = r.course_id;
