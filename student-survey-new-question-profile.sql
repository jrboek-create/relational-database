\set ON_ERROR_STOP on

WITH all_new_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        source_row_number,

        NULLIF(BTRIM(c0001), '') AS response_id,

        NULLIF(BTRIM(c0023), '') AS q1,
        NULLIF(BTRIM(c0024), '') AS q2,
        NULLIF(BTRIM(c0025), '') AS q3,
        NULLIF(BTRIM(c0026), '') AS q4,
        NULLIF(BTRIM(c0027), '') AS q5,
        NULLIF(BTRIM(c0028), '') AS q6,
        NULLIF(BTRIM(c0029), '') AS q7,

        NULLIF(BTRIM(c0031), '') AS q9,
        NULLIF(BTRIM(c0032), '') AS q10,
        NULLIF(BTRIM(c0033), '') AS q11,

        NULLIF(BTRIM(c0035), '') AS q13

    FROM staging.raw_master_online_new_s02_spots_3caa2498

    UNION ALL

    SELECT
        2,
        34,
        source_row_number,

        NULLIF(BTRIM(c0001), ''),

        NULLIF(BTRIM(c0023), ''),
        NULLIF(BTRIM(c0024), ''),
        NULLIF(BTRIM(c0025), ''),
        NULLIF(BTRIM(c0026), ''),
        NULLIF(BTRIM(c0027), ''),
        NULLIF(BTRIM(c0028), ''),
        NULLIF(BTRIM(c0029), ''),

        NULLIF(BTRIM(c0031), ''),
        NULLIF(BTRIM(c0032), ''),
        NULLIF(BTRIM(c0033), ''),

        NULLIF(BTRIM(c0035), '')

    FROM staging.raw_master_online_new_s01_rawdata_3caa2498
),

valid_rows AS (
    SELECT *
    FROM all_new_rows

    WHERE response_id IS NOT NULL
      AND LOWER(BTRIM(response_id)) NOT IN (
          'responseuniqueid',
          'response unique id',
          'response_id',
          'responseid'
      )
),

deduplicated AS (
    SELECT
        response_id,
        q1,
        q2,
        q3,
        q4,
        q5,
        q6,
        q7,
        q9,
        q10,
        q11,
        q13

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

        FROM valid_rows v
    ) ranked

    WHERE response_rank = 1
),

question_values AS (
    SELECT 1 AS question_number, 'Q1'::text AS question_code, q1 AS raw_value
    FROM deduplicated

    UNION ALL

    SELECT 2, 'Q2', q2
    FROM deduplicated

    UNION ALL

    SELECT 3, 'Q3', q3
    FROM deduplicated

    UNION ALL

    SELECT 4, 'Q4', q4
    FROM deduplicated

    UNION ALL

    SELECT 5, 'Q5', q5
    FROM deduplicated

    UNION ALL

    SELECT 6, 'Q6', q6
    FROM deduplicated

    UNION ALL

    SELECT 7, 'Q7', q7
    FROM deduplicated

    UNION ALL

    SELECT 9, 'Q9', q9
    FROM deduplicated

    UNION ALL

    SELECT 10, 'Q10', q10
    FROM deduplicated

    UNION ALL

    SELECT 11, 'Q11', q11
    FROM deduplicated

    UNION ALL

    SELECT 13, 'Q13', q13
    FROM deduplicated
),

classified AS (
    SELECT
        question_number,
        question_code,
        raw_value,

        CASE
            WHEN raw_value IN ('1', '2', '3', '4', '5')
            THEN raw_value::numeric
            ELSE NULL
        END AS rating

    FROM question_values
),

question_profile AS (
    SELECT
        question_number,
        question_code,

        COUNT(*)::bigint AS deduplicated_responses,

        SUM(
            CASE
                WHEN raw_value IS NOT NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS populated_responses,

        SUM(
            CASE
                WHEN rating IS NOT NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS valid_rating_responses,

        SUM(
            CASE
                WHEN raw_value IS NOT NULL
                 AND rating IS NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS invalid_or_nonnumeric_responses,

        MIN(rating) AS minimum_rating,
        MAX(rating) AS maximum_rating,

        ROUND(
            AVG(rating),
            4
        ) AS average_rating,

        COUNT(
            DISTINCT rating
        )::bigint AS distinct_rating_values

    FROM classified

    GROUP BY
        question_number,
        question_code
)

SELECT
    p.question_code,

    m.c0002 AS question_title,

    p.deduplicated_responses,
    p.populated_responses,
    p.valid_rating_responses,
    p.invalid_or_nonnumeric_responses,
    p.minimum_rating,
    p.maximum_rating,
    p.average_rating,
    p.distinct_rating_values

FROM question_profile p

LEFT JOIN staging.raw_master_online_new_s03_questionmapper_3caa2498 m
    ON BTRIM(m.c0001) =
        'Question ' || p.question_number::text

ORDER BY p.question_number;
