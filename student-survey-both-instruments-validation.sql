\set ON_ERROR_STOP on

/*
    STUDENT SURVEY BOTH-INSTRUMENT VALIDATION

    NEW instrument rating questions:
      Q1-Q7, Q9-Q11, Q13

    OLD instrument rating questions:
      Q1-Q8,
      Q11-Q12,
      Q14-Q17,
      Q19-Q24,
      Q26,
      Q28

    Intentionally excluded:
      NEW Q8, Q12       Free text
      NEW Q14           Weekly hours
      OLD Q10, Q13      Free text
      OLD Q18           Weekly hours
      OLD Q25, Q27, Q29 Free text

    OLD Q9 is profiled separately because the wording indicates
    a likelihood/recommendation measure whose scale must be proven
    rather than assumed to be 1-5.
*/


/* ============================================================
   RESULT SET 1
   QUESTION-BY-QUESTION SCALE AND POPULATION PROFILE
   ============================================================ */

WITH all_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        'NEW'::text AS survey_version,
        source_row_number,
        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id,
        to_jsonb(s) AS source_payload
    FROM staging.raw_master_online_new_s02_spots_3caa2498 s

    UNION ALL

    SELECT
        2,
        34,
        'NEW'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        to_jsonb(s)
    FROM staging.raw_master_online_new_s01_rawdata_3caa2498 s

    UNION ALL

    SELECT
        3,
        37,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        to_jsonb(s)
    FROM staging.raw_master_online_part_s01_online_31fb6e24 s

    UNION ALL

    SELECT
        4,
        40,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        to_jsonb(s)
    FROM staging.raw_master_online_part_s01_online_3417e822 s

    UNION ALL

    SELECT
        5,
        41,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        to_jsonb(s)
    FROM staging.raw_master_online_part_s01_online_324dd997 s

    UNION ALL

    SELECT
        6,
        42,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        to_jsonb(s)
    FROM staging.raw_master_online_part_s01_online_6164ddea s
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
        component_id,
        survey_version,
        source_row_number,
        response_id,
        course_code,
        unique_id,
        source_payload
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

question_catalog AS (
    SELECT *
    FROM (
        VALUES
            ('NEW'::text,  1, 'Q1'::text,  'c0023'::text, '1-5'::text),
            ('NEW'::text,  2, 'Q2'::text,  'c0024'::text, '1-5'::text),
            ('NEW'::text,  3, 'Q3'::text,  'c0025'::text, '1-5'::text),
            ('NEW'::text,  4, 'Q4'::text,  'c0026'::text, '1-5'::text),
            ('NEW'::text,  5, 'Q5'::text,  'c0027'::text, '1-5'::text),
            ('NEW'::text,  6, 'Q6'::text,  'c0028'::text, '1-5'::text),
            ('NEW'::text,  7, 'Q7'::text,  'c0029'::text, '1-5'::text),
            ('NEW'::text,  9, 'Q9'::text,  'c0031'::text, '1-5'::text),
            ('NEW'::text, 10, 'Q10'::text, 'c0032'::text, '1-5'::text),
            ('NEW'::text, 11, 'Q11'::text, 'c0033'::text, '1-5'::text),
            ('NEW'::text, 13, 'Q13'::text, 'c0035'::text, '1-5'::text),

            ('OLD'::text,  1, 'Q1'::text,  'c0023'::text, '1-5'::text),
            ('OLD'::text,  2, 'Q2'::text,  'c0024'::text, '1-5'::text),
            ('OLD'::text,  3, 'Q3'::text,  'c0025'::text, '1-5'::text),
            ('OLD'::text,  4, 'Q4'::text,  'c0026'::text, '1-5'::text),
            ('OLD'::text,  5, 'Q5'::text,  'c0027'::text, '1-5'::text),
            ('OLD'::text,  6, 'Q6'::text,  'c0028'::text, '1-5'::text),
            ('OLD'::text,  7, 'Q7'::text,  'c0029'::text, '1-5'::text),
            ('OLD'::text,  8, 'Q8'::text,  'c0030'::text, '1-5'::text),

            /*
                OLD Q9 is intentionally not assumed to be 1-5.
                The output will prove its actual observed scale.
            */
            ('OLD'::text,  9, 'Q9'::text,  'c0031'::text, 'PROFILE'::text),

            ('OLD'::text, 11, 'Q11'::text, 'c0033'::text, '1-5'::text),
            ('OLD'::text, 12, 'Q12'::text, 'c0034'::text, '1-5'::text),
            ('OLD'::text, 14, 'Q14'::text, 'c0036'::text, '1-5'::text),
            ('OLD'::text, 15, 'Q15'::text, 'c0037'::text, '1-5'::text),
            ('OLD'::text, 16, 'Q16'::text, 'c0038'::text, '1-5'::text),
            ('OLD'::text, 17, 'Q17'::text, 'c0039'::text, '1-5'::text),
            ('OLD'::text, 19, 'Q19'::text, 'c0041'::text, '1-5'::text),
            ('OLD'::text, 20, 'Q20'::text, 'c0042'::text, '1-5'::text),
            ('OLD'::text, 21, 'Q21'::text, 'c0043'::text, '1-5'::text),
            ('OLD'::text, 22, 'Q22'::text, 'c0044'::text, '1-5'::text),
            ('OLD'::text, 23, 'Q23'::text, 'c0045'::text, '1-5'::text),
            ('OLD'::text, 24, 'Q24'::text, 'c0046'::text, '1-5'::text),
            ('OLD'::text, 26, 'Q26'::text, 'c0048'::text, '1-5'::text),
            ('OLD'::text, 28, 'Q28'::text, 'c0050'::text, '1-5'::text)
    ) q (
        survey_version,
        question_number,
        question_code,
        source_column,
        expected_scale
    )
),

question_titles AS (
    SELECT
        'NEW'::text AS survey_version,
        BTRIM(c0001) AS mapper_question,
        BTRIM(c0002) AS question_title
    FROM staging.raw_master_online_new_s03_questionmapper_3caa2498
    WHERE BTRIM(c0001) LIKE 'Question %'

    UNION ALL

    SELECT
        'OLD'::text,
        BTRIM(c0001),
        BTRIM(c0002)
    FROM staging.raw_master_online_part_s03_questionmapper_31fb6e24
    WHERE BTRIM(c0001) LIKE 'Question %'
),

question_values AS (
    SELECT
        q.survey_version,
        q.question_number,
        q.question_code,
        q.source_column,
        q.expected_scale,
        d.response_id,

        NULLIF(
            BTRIM(
                d.source_payload ->> q.source_column
            ),
            ''
        ) AS raw_value

    FROM deduplicated_responses d

    JOIN question_catalog q
        ON q.survey_version = d.survey_version
),

classified AS (
    SELECT
        survey_version,
        question_number,
        question_code,
        source_column,
        expected_scale,
        response_id,
        raw_value,

        CASE
            WHEN raw_value ~ '^[+-]?[0-9]+([.][0-9]+)?$'
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

question_profile AS (
    SELECT
        survey_version,
        question_number,
        question_code,
        source_column,
        expected_scale,

        COUNT(DISTINCT response_id)::bigint
            AS deduplicated_responses,

        SUM(
            CASE
                WHEN raw_value IS NOT NULL
                THEN 1 ELSE 0
            END
        )::bigint AS populated_responses,

        SUM(
            CASE
                WHEN rating_1_to_5 IS NOT NULL
                THEN 1 ELSE 0
            END
        )::bigint AS valid_1_to_5_responses,

        SUM(
            CASE
                WHEN numeric_value IS NOT NULL
                 AND rating_1_to_5 IS NULL
                THEN 1 ELSE 0
            END
        )::bigint AS numeric_outside_1_to_5,

        SUM(
            CASE
                WHEN raw_value IS NOT NULL
                 AND numeric_value IS NULL
                THEN 1 ELSE 0
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
        survey_version,
        question_number,
        question_code,
        source_column,
        expected_scale
)

SELECT
    p.survey_version,
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
         AND (
             p.populated_responses = 0
             OR (
                 p.observed_minimum >= 1
                 AND p.observed_maximum <= 5
             )
         )
        THEN 'PASS_1_TO_5'

        WHEN p.expected_scale = 'PROFILE'
        THEN 'REVIEW_OBSERVED_SCALE'

        ELSE 'REVIEW'
    END AS validation_status

FROM question_profile p

LEFT JOIN question_titles t
    ON t.survey_version = p.survey_version
   AND t.mapper_question =
       'Question ' || p.question_number::text

ORDER BY
    CASE
        WHEN p.survey_version = 'NEW'
        THEN 1
        ELSE 2
    END,
    p.question_number;


/* ============================================================
   RESULT SET 2
   GOVERNED INSTRUMENT COVERAGE AND TOGGLE ELIGIBILITY
   ============================================================ */

WITH all_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        'NEW'::text AS survey_version,
        source_row_number,
        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id
    FROM staging.raw_master_online_new_s02_spots_3caa2498

    UNION ALL

    SELECT
        2,
        34,
        'NEW'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_new_s01_rawdata_3caa2498

    UNION ALL

    SELECT
        3,
        37,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_31fb6e24

    UNION ALL

    SELECT
        4,
        40,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_3417e822

    UNION ALL

    SELECT
        5,
        41,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_324dd997

    UNION ALL

    SELECT
        6,
        42,
        'OLD'::text,
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
        survey_version,
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
        survey_version,
        response_id,

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

matched_responses AS (
    SELECT
        n.survey_version,
        n.response_id,
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

course_instrument_profile AS (
    SELECT
        course_id,

        COUNT(DISTINCT response_id) FILTER (
            WHERE survey_version = 'OLD'
        )::bigint AS old_response_count,

        COUNT(DISTINCT response_id) FILTER (
            WHERE survey_version = 'NEW'
        )::bigint AS new_response_count,

        COUNT(DISTINCT term_id) FILTER (
            WHERE survey_version = 'OLD'
        )::bigint AS old_term_count,

        COUNT(DISTINCT term_id) FILTER (
            WHERE survey_version = 'NEW'
        )::bigint AS new_term_count

    FROM matched_responses

    GROUP BY course_id
),

course_term_profile AS (
    SELECT
        course_id,
        term_id,

        COUNT(DISTINCT survey_version)::bigint
            AS instrument_count

    FROM matched_responses

    GROUP BY
        course_id,
        term_id
),

overall AS (
    SELECT
        COUNT(*)::bigint AS represented_courses,

        SUM(
            CASE
                WHEN old_response_count > 0
                 AND new_response_count = 0
                THEN 1 ELSE 0
            END
        )::bigint AS courses_with_old_only,

        SUM(
            CASE
                WHEN old_response_count = 0
                 AND new_response_count > 0
                THEN 1 ELSE 0
            END
        )::bigint AS courses_with_new_only,

        SUM(
            CASE
                WHEN old_response_count > 0
                 AND new_response_count > 0
                THEN 1 ELSE 0
            END
        )::bigint AS courses_with_both_instruments,

        SUM(old_response_count)::bigint
            AS governed_old_responses,

        SUM(new_response_count)::bigint
            AS governed_new_responses,

        SUM(old_term_count)::bigint
            AS governed_old_course_terms,

        SUM(new_term_count)::bigint
            AS governed_new_course_terms

    FROM course_instrument_profile
),

term_overlap AS (
    SELECT
        COUNT(*) FILTER (
            WHERE instrument_count > 1
        )::bigint AS course_terms_with_both_instruments

    FROM course_term_profile
)

SELECT
    o.represented_courses,
    o.courses_with_old_only,
    o.courses_with_new_only,
    o.courses_with_both_instruments,

    o.governed_old_responses,
    o.governed_new_responses,

    o.governed_old_course_terms,
    o.governed_new_course_terms,

    t.course_terms_with_both_instruments,

    CASE
        WHEN o.courses_with_both_instruments > 0
        THEN 'TOGGLE_SUPPORTED'
        ELSE 'NO_COURSES_REQUIRE_TOGGLE'
    END AS instrument_toggle_status

FROM overall o
CROSS JOIN term_overlap t;


/* ============================================================
   RESULT SET 3
   ASCI 254 INSTRUMENT HISTORY ACCEPTANCE
   ============================================================ */

WITH all_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        'NEW'::text AS survey_version,
        source_row_number,
        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id
    FROM staging.raw_master_online_new_s02_spots_3caa2498

    UNION ALL

    SELECT
        2,
        34,
        'NEW'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_new_s01_rawdata_3caa2498

    UNION ALL

    SELECT
        3,
        37,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_31fb6e24

    UNION ALL

    SELECT
        4,
        40,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_3417e822

    UNION ALL

    SELECT
        5,
        41,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), '')
    FROM staging.raw_master_online_part_s01_online_324dd997

    UNION ALL

    SELECT
        6,
        42,
        'OLD'::text,
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
        survey_version,
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
        survey_version,
        response_id,

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

matched_responses AS (
    SELECT
        n.survey_version,
        n.response_id,
        t.term_id,
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
    t.term_code,
    t.term_label,
    m.survey_version,

    COUNT(DISTINCT m.response_id)::bigint
        AS student_response_count

FROM matched_responses m

JOIN core.term t
    ON t.term_id = m.term_id

WHERE m.course_id =
    '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid

GROUP BY
    t.term_id,
    t.term_code,
    t.term_label,
    m.survey_version

ORDER BY
    CASE
        WHEN t.term_code ~ '^[0-9]+$'
        THEN t.term_code::integer
        ELSE NULL
    END DESC,
    m.survey_version;
