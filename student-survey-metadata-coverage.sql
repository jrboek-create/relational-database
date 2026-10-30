\set ON_ERROR_STOP on

WITH all_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        source_row_number,
        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id
    FROM staging.raw_master_online_new_s02_spots_3caa2498

    UNION ALL

    SELECT
        2,
        34,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_new_s01_rawdata_3caa2498

    UNION ALL

    SELECT
        3,
        37,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_31fb6e24

    UNION ALL

    SELECT
        4,
        40,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_3417e822

    UNION ALL

    SELECT
        5,
        41,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_324dd997

    UNION ALL

    SELECT
        6,
        42,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
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
        response_id,
        course_code,
        unique_id
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
        SPLIT_PART(
            unique_id,
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
            unique_id,
            '_',
            5
        ) AS candidate_source_identifier

    FROM deduplicated_responses
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
    COUNT(*)::bigint
        AS represented_courses,

    SUM(
        CASE
            WHEN d.course_id IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint
        AS courses_with_catalog_detail,

    SUM(
        CASE
            WHEN d.course_id IS NULL
            THEN 1
            ELSE 0
        END
    )::bigint
        AS courses_without_catalog_detail,

    SUM(
        CASE
            WHEN NULLIF(BTRIM(d.university_course_id), '') IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint
        AS courses_with_university_course_id,

    SUM(
        CASE
            WHEN NULLIF(BTRIM(d.course_code), '') IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint
        AS courses_with_course_code,

    SUM(
        CASE
            WHEN NULLIF(BTRIM(d.course_title), '') IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint
        AS courses_with_course_title,

    SUM(
        CASE
            WHEN NULLIF(BTRIM(d.college_name), '') IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint
        AS courses_with_college,

    SUM(
        CASE
            WHEN NULLIF(BTRIM(d.department_name), '') IS NOT NULL
            THEN 1
            ELSE 0
        END
    )::bigint
        AS courses_with_department

FROM represented_courses r

LEFT JOIN reporting.course_catalog_detail d
    ON d.course_id = r.course_id;
