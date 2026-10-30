\set ON_ERROR_STOP on

WITH old_source_rows AS (
    SELECT
        1 AS source_priority,
        37 AS component_id,
        source_row_number,
        NULLIF(BTRIM(c0001), '') AS response_id,
        TO_JSONB(s) AS payload
    FROM staging.raw_master_online_part_s01_online_31fb6e24 s

    UNION ALL

    SELECT
        2,
        40,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        TO_JSONB(s)
    FROM staging.raw_master_online_part_s01_online_3417e822 s

    UNION ALL

    SELECT
        3,
        41,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        TO_JSONB(s)
    FROM staging.raw_master_online_part_s01_online_324dd997 s

    UNION ALL

    SELECT
        4,
        42,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        TO_JSONB(s)
    FROM staging.raw_master_online_part_s01_online_6164ddea s
),

valid_rows AS (
    SELECT
        source_priority,
        component_id,
        source_row_number,
        response_id,
        payload
    FROM old_source_rows
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
        payload
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

question_catalog AS (
    SELECT *
    FROM (
        VALUES
            (1,  'Q1',  'c0023', '1-5'),
            (2,  'Q2',  'c0024', '1-5'),
            (3,  'Q3',  'c0025', '1-5'),
            (4,  'Q4',  'c0026', '1-5'),
            (5,  'Q5',  'c0027', '1-5'),
            (6,  'Q6',  'c0028', '1-5'),
            (7,  'Q7',  'c0029', '1-5'),
            (8,  'Q8',  'c0030', '1-5'),

            /*
              OLD Q9 asks how likely a student would recommend
              the instructor. Its observed scale is profiled,
              not assumed.
            */
            (9,  'Q9',  'c0031', 'PROFILE'),

            (11, 'Q11', 'c0033', '1-5'),
            (12, 'Q12', 'c0034', '1-5'),
            (14, 'Q14', 'c0036', '1-5'),
            (15, 'Q15', 'c0037', '1-5'),
            (16, 'Q16', 'c0038', '1-5'),
            (17, 'Q17', 'c0039', '1-5'),
            (19, 'Q19', 'c0041', '1-5'),
            (20, 'Q20', 'c0042', '1-5'),
            (21, 'Q21', 'c0043', '1-5'),
            (22, 'Q22', 'c0044', '1-5'),
            (23, 'Q23', 'c0045', '1-5'),
            (24, 'Q24', 'c0046', '1-5'),
            (26, 'Q26', 'c0048', '1-5'),
            (28, 'Q28', 'c0050', '1-5')
    ) q (
        question_number,
        question_code,
        source_column,
        expected_scale
    )
),

question_values AS (
    SELECT
        q.question_number,
        q.question_code,
        q.source_column,
        q.expected_scale,
        d.response_id,
        NULLIF(
            BTRIM(d.payload ->> q.source_column),
            ''
        ) AS raw_value
    FROM deduplicated d
    CROSS JOIN question_catalog q
),

classified AS (
    SELECT
        question_number,
        question_code,
        source_column,
        expected_scale,
        response_id,
        raw_value,

        CASE
            WHEN raw_value ~ '^[0-9]+([.][0-9]+)?$'
            THEN raw_value::numeric
            ELSE NULL
        END AS numeric_value,

        CASE
            WHEN raw_value IN ('1', '2', '3', '4', '5')
            THEN raw_value::numeric
            ELSE NULL
        END AS rating_1_to_5
    FROM question_values
),

profile AS (
    SELECT
        question_number,
        question_code,
        source_column,
        expected_scale,

        COUNT(DISTINCT response_id)::bigint
            AS deduplicated_responses,

        SUM(
            CASE
                WHEN raw_value IS NOT NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS populated_responses,

        SUM(
            CASE
                WHEN rating_1_to_5 IS NOT NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS valid_1_to_5_responses,

        SUM(
            CASE
                WHEN numeric_value IS NOT NULL
                 AND rating_1_to_5 IS NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS numeric_outside_1_to_5,

        SUM(
            CASE
                WHEN raw_value IS NOT NULL
                 AND numeric_value IS NULL
                THEN 1
                ELSE 0
            END
        )::bigint AS nonnumeric_responses,

        MIN(numeric_value) AS observed_minimum,
        MAX(numeric_value) AS observed_maximum,

        ROUND(
            AVG(rating_1_to_5),
            4
        ) AS average_1_to_5_rating,

        COUNT(DISTINCT numeric_value)::bigint
            AS distinct_numeric_values

    FROM classified

    GROUP BY
        question_number,
        question_code,
        source_column,
        expected_scale
),

question_titles AS (
    SELECT
        BTRIM(c0001) AS mapper_question,
        BTRIM(c0002) AS question_title
    FROM staging.raw_master_online_part_s03_questionmapper_31fb6e24
    WHERE BTRIM(c0001) LIKE 'Question %'
)

SELECT
    p.question_code,
    t.question_title,
    p.source_column,
    p.expected_scale,
    p.deduplicated_responses,
    p.populated_responses,
    p.valid_1_to_5_responses,
    p.numeric_outside_1_to_5,
    p.nonnumeric_responses,
    p.observed_minimum,
    p.observed_maximum,
    p.average_1_to_5_rating,
    p.distinct_numeric_values,

    CASE
        WHEN p.expected_scale = '1-5'
         AND p.populated_responses =
             p.valid_1_to_5_responses
         AND p.numeric_outside_1_to_5 = 0
         AND p.nonnumeric_responses = 0
        THEN 'PASS_1_TO_5'

        WHEN p.expected_scale = 'PROFILE'
        THEN 'REVIEW_OBSERVED_SCALE'

        ELSE 'REVIEW'
    END AS validation_status

FROM profile p

LEFT JOIN question_titles t
    ON t.mapper_question =
        'Question ' || p.question_number::text

ORDER BY p.question_number;
