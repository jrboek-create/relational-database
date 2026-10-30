\set ON_ERROR_STOP on

WITH new_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        source_row_number,

        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id,

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
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),

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

new_valid_rows AS (
    SELECT *
    FROM new_source_rows

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

new_deduplicated AS (
    SELECT
        response_id,
        course_code,
        unique_id,
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
            n.*,

            ROW_NUMBER() OVER (
                PARTITION BY response_id
                ORDER BY
                    source_priority,
                    component_id,
                    source_row_number
            ) AS response_rank

        FROM new_valid_rows n
    ) ranked

    WHERE response_rank = 1
),

new_matched AS (
    SELECT
        'NEW'::text AS survey_version,
        n.response_id,

        t.term_id,
        t.term_code,
        t.term_label,

        o.course_id,

        n.q1,
        n.q2,
        n.q3,
        n.q4,
        n.q5,
        n.q6,
        n.q7,
        n.q9,
        n.q10,
        n.q11,
        n.q13

    FROM new_deduplicated n

    JOIN core.term t
        ON BTRIM(t.term_code) =
           SPLIT_PART(n.unique_id, '_', 1)

    JOIN core.course_offering_section o
        ON o.term_id = t.term_id

       AND UPPER(BTRIM(o.source_identifier)) =
           UPPER(
               REGEXP_REPLACE(
                   n.course_code,
                   '[^A-Za-z0-9]',
                   '',
                   'g'
               )
           )
           || '_'
           || SPLIT_PART(n.unique_id, '_', 5)
),

new_question_values AS (
    SELECT
        n.survey_version,
        n.response_id,
        n.course_id,
        n.term_id,
        n.term_code,
        n.term_label,

        q.question_number,
        q.question_code,

        q.raw_value::numeric AS rating

    FROM new_matched n

    CROSS JOIN LATERAL (
        VALUES
            (1,  'Q1'::text,  n.q1),
            (2,  'Q2'::text,  n.q2),
            (3,  'Q3'::text,  n.q3),
            (4,  'Q4'::text,  n.q4),
            (5,  'Q5'::text,  n.q5),
            (6,  'Q6'::text,  n.q6),
            (7,  'Q7'::text,  n.q7),
            (9,  'Q9'::text,  n.q9),
            (10, 'Q10'::text, n.q10),
            (11, 'Q11'::text, n.q11),
            (13, 'Q13'::text, n.q13)
    ) q (
        question_number,
        question_code,
        raw_value
    )

    WHERE q.raw_value IN (
        '1',
        '2',
        '3',
        '4',
        '5'
    )
),

old_source_rows AS (
    SELECT
        1 AS source_priority,
        37 AS component_id,
        source_row_number,

        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id,

        NULLIF(BTRIM(c0023), '') AS q1,
        NULLIF(BTRIM(c0024), '') AS q2,
        NULLIF(BTRIM(c0025), '') AS q3,
        NULLIF(BTRIM(c0026), '') AS q4,
        NULLIF(BTRIM(c0027), '') AS q5,
        NULLIF(BTRIM(c0028), '') AS q6,
        NULLIF(BTRIM(c0029), '') AS q7,
        NULLIF(BTRIM(c0030), '') AS q8,
        NULLIF(BTRIM(c0031), '') AS q9,

        NULLIF(BTRIM(c0033), '') AS q11,
        NULLIF(BTRIM(c0034), '') AS q12,

        NULLIF(BTRIM(c0036), '') AS q14,
        NULLIF(BTRIM(c0037), '') AS q15,
        NULLIF(BTRIM(c0038), '') AS q16,
        NULLIF(BTRIM(c0039), '') AS q17,

        NULLIF(BTRIM(c0041), '') AS q19,
        NULLIF(BTRIM(c0042), '') AS q20,
        NULLIF(BTRIM(c0043), '') AS q21,
        NULLIF(BTRIM(c0044), '') AS q22,
        NULLIF(BTRIM(c0045), '') AS q23,
        NULLIF(BTRIM(c0046), '') AS q24,

        NULLIF(BTRIM(c0048), '') AS q26,
        NULLIF(BTRIM(c0050), '') AS q28

    FROM staging.raw_master_online_part_s01_online_31fb6e24

    UNION ALL

    SELECT
        2,
        40,
        source_row_number,

        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),

        NULLIF(BTRIM(c0023), ''),
        NULLIF(BTRIM(c0024), ''),
        NULLIF(BTRIM(c0025), ''),
        NULLIF(BTRIM(c0026), ''),
        NULLIF(BTRIM(c0027), ''),
        NULLIF(BTRIM(c0028), ''),
        NULLIF(BTRIM(c0029), ''),
        NULLIF(BTRIM(c0030), ''),
        NULLIF(BTRIM(c0031), ''),

        NULLIF(BTRIM(c0033), ''),
        NULLIF(BTRIM(c0034), ''),

        NULLIF(BTRIM(c0036), ''),
        NULLIF(BTRIM(c0037), ''),
        NULLIF(BTRIM(c0038), ''),
        NULLIF(BTRIM(c0039), ''),

        NULLIF(BTRIM(c0041), ''),
        NULLIF(BTRIM(c0042), ''),
        NULLIF(BTRIM(c0043), ''),
        NULLIF(BTRIM(c0044), ''),
        NULLIF(BTRIM(c0045), ''),
        NULLIF(BTRIM(c0046), ''),

        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')

    FROM staging.raw_master_online_part_s01_online_3417e822

    UNION ALL

    SELECT
        3,
        41,
        source_row_number,

        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),

        NULLIF(BTRIM(c0023), ''),
        NULLIF(BTRIM(c0024), ''),
        NULLIF(BTRIM(c0025), ''),
        NULLIF(BTRIM(c0026), ''),
        NULLIF(BTRIM(c0027), ''),
        NULLIF(BTRIM(c0028), ''),
        NULLIF(BTRIM(c0029), ''),
        NULLIF(BTRIM(c0030), ''),
        NULLIF(BTRIM(c0031), ''),

        NULLIF(BTRIM(c0033), ''),
        NULLIF(BTRIM(c0034), ''),

        NULLIF(BTRIM(c0036), ''),
        NULLIF(BTRIM(c0037), ''),
        NULLIF(BTRIM(c0038), ''),
        NULLIF(BTRIM(c0039), ''),

        NULLIF(BTRIM(c0041), ''),
        NULLIF(BTRIM(c0042), ''),
        NULLIF(BTRIM(c0043), ''),
        NULLIF(BTRIM(c0044), ''),
        NULLIF(BTRIM(c0045), ''),
        NULLIF(BTRIM(c0046), ''),

        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')

    FROM staging.raw_master_online_part_s01_online_324dd997

    UNION ALL

    SELECT
        4,
        42,
        source_row_number,

        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),

        NULLIF(BTRIM(c0023), ''),
        NULLIF(BTRIM(c0024), ''),
        NULLIF(BTRIM(c0025), ''),
        NULLIF(BTRIM(c0026), ''),
        NULLIF(BTRIM(c0027), ''),
        NULLIF(BTRIM(c0028), ''),
        NULLIF(BTRIM(c0029), ''),
        NULLIF(BTRIM(c0030), ''),
        NULLIF(BTRIM(c0031), ''),

        NULLIF(BTRIM(c0033), ''),
        NULLIF(BTRIM(c0034), ''),

        NULLIF(BTRIM(c0036), ''),
        NULLIF(BTRIM(c0037), ''),
        NULLIF(BTRIM(c0038), ''),
        NULLIF(BTRIM(c0039), ''),

        NULLIF(BTRIM(c0041), ''),
        NULLIF(BTRIM(c0042), ''),
        NULLIF(BTRIM(c0043), ''),
        NULLIF(BTRIM(c0044), ''),
        NULLIF(BTRIM(c0045), ''),
        NULLIF(BTRIM(c0046), ''),

        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')

    FROM staging.raw_master_online_part_s01_online_6164ddea
),

old_valid_rows AS (
    SELECT *
    FROM old_source_rows

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

old_deduplicated AS (
    SELECT
        response_id,
        course_code,
        unique_id,

        q1,
        q2,
        q3,
        q4,
        q5,
        q6,
        q7,
        q8,
        q9,
        q11,
        q12,
        q14,
        q15,
        q16,
        q17,
        q19,
        q20,
        q21,
        q22,
        q23,
        q24,
        q26,
        q28

    FROM (
        SELECT
            o.*,

            ROW_NUMBER() OVER (
                PARTITION BY response_id
                ORDER BY
                    source_priority,
                    component_id,
                    source_row_number
            ) AS response_rank

        FROM old_valid_rows o
    ) ranked

    WHERE response_rank = 1
),

old_matched AS (
    SELECT
        'OLD'::text AS survey_version,
        o.response_id,

        t.term_id,
        t.term_code,
        t.term_label,

        s.course_id,

        o.q1,
        o.q2,
        o.q3,
        o.q4,
        o.q5,
        o.q6,
        o.q7,
        o.q8,
        o.q9,
        o.q11,
        o.q12,
        o.q14,
        o.q15,
        o.q16,
        o.q17,
        o.q19,
        o.q20,
        o.q21,
        o.q22,
        o.q23,
        o.q24,
        o.q26,
        o.q28

    FROM old_deduplicated o

    JOIN core.term t
        ON BTRIM(t.term_code) =
           SPLIT_PART(o.unique_id, '_', 1)

    JOIN core.course_offering_section s
        ON s.term_id = t.term_id

       AND UPPER(BTRIM(s.source_identifier)) =
           UPPER(
               REGEXP_REPLACE(
                   o.course_code,
                   '[^A-Za-z0-9]',
                   '',
                   'g'
               )
           )
           || '_'
           || SPLIT_PART(o.unique_id, '_', 5)
),

old_question_values AS (
    SELECT
        o.survey_version,
        o.response_id,
        o.course_id,
        o.term_id,
        o.term_code,
        o.term_label,

        q.question_number,
        q.question_code,

        q.raw_value::numeric AS rating

    FROM old_matched o

    CROSS JOIN LATERAL (
        VALUES
            (1,  'Q1'::text,  o.q1),
            (2,  'Q2'::text,  o.q2),
            (3,  'Q3'::text,  o.q3),
            (4,  'Q4'::text,  o.q4),
            (5,  'Q5'::text,  o.q5),
            (6,  'Q6'::text,  o.q6),
            (7,  'Q7'::text,  o.q7),
            (8,  'Q8'::text,  o.q8),
            (9,  'Q9'::text,  o.q9),
            (11, 'Q11'::text, o.q11),
            (12, 'Q12'::text, o.q12),
            (14, 'Q14'::text, o.q14),
            (15, 'Q15'::text, o.q15),
            (16, 'Q16'::text, o.q16),
            (17, 'Q17'::text, o.q17),
            (19, 'Q19'::text, o.q19),
            (20, 'Q20'::text, o.q20),
            (21, 'Q21'::text, o.q21),
            (22, 'Q22'::text, o.q22),
            (23, 'Q23'::text, o.q23),
            (24, 'Q24'::text, o.q24),
            (26, 'Q26'::text, o.q26),
            (28, 'Q28'::text, o.q28)
    ) q (
        question_number,
        question_code,
        raw_value
    )

    WHERE q.raw_value IN (
        '1',
        '2',
        '3',
        '4',
        '5'
    )
),

all_question_values AS (
    SELECT *
    FROM new_question_values

    UNION ALL

    SELECT *
    FROM old_question_values
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

question_summary AS (
    SELECT
        q.course_id,
        q.term_id,
        q.term_code,
        q.term_label,
        q.survey_version,
        q.question_number,
        q.question_code,

        MAX(t.question_title) AS question_title,

        COUNT(DISTINCT q.response_id)::bigint
            AS valid_response_count,

        ROUND(
            AVG(q.rating),
            4
        ) AS average_rating,

        MIN(q.rating) AS minimum_rating,
        MAX(q.rating) AS maximum_rating

    FROM all_question_values q

    JOIN question_titles t
        ON t.survey_version = q.survey_version

       AND t.mapper_question =
           'Question ' || q.question_number::text

    GROUP BY
        q.course_id,
        q.term_id,
        q.term_code,
        q.term_label,
        q.survey_version,
        q.question_number,
        q.question_code
),

instrument_course_profile AS (
    SELECT
        course_id,

        COUNT(*) FILTER (
            WHERE survey_version = 'OLD'
        )::bigint AS old_question_rows,

        COUNT(*) FILTER (
            WHERE survey_version = 'NEW'
        )::bigint AS new_question_rows

    FROM question_summary

    GROUP BY course_id
),

instrument_course_term_profile AS (
    SELECT
        course_id,
        term_id,

        COUNT(DISTINCT survey_version)::bigint
            AS instrument_count

    FROM question_summary

    GROUP BY
        course_id,
        term_id
),

global_summary AS (
    SELECT
        COUNT(*)::bigint
            AS question_summary_rows,

        COUNT(DISTINCT course_id)::bigint
            AS represented_courses,

        COUNT(DISTINCT term_id)::bigint
            AS represented_terms,

        COUNT(
            DISTINCT course_id::text
            || ':'
            || term_id::text
            || ':'
            || survey_version
        )::bigint AS course_term_instrument_groups,

        COUNT(*) FILTER (
            WHERE survey_version = 'OLD'
        )::bigint AS old_question_summary_rows,

        COUNT(*) FILTER (
            WHERE survey_version = 'NEW'
        )::bigint AS new_question_summary_rows,

        COUNT(
            DISTINCT question_code
        ) FILTER (
            WHERE survey_version = 'OLD'
        )::bigint AS old_question_count,

        COUNT(
            DISTINCT question_code
        ) FILTER (
            WHERE survey_version = 'NEW'
        )::bigint AS new_question_count,

        SUM(valid_response_count) FILTER (
            WHERE survey_version = 'OLD'
        )::bigint AS old_valid_question_responses,

        SUM(valid_response_count) FILTER (
            WHERE survey_version = 'NEW'
        )::bigint AS new_valid_question_responses,

        ROUND(
            SUM(
                average_rating
                * valid_response_count
            ) FILTER (
                WHERE survey_version = 'OLD'
            )
            /
            NULLIF(
                SUM(valid_response_count) FILTER (
                    WHERE survey_version = 'OLD'
                ),
                0
            ),
            4
        ) AS weighted_old_average,

        ROUND(
            SUM(
                average_rating
                * valid_response_count
            ) FILTER (
                WHERE survey_version = 'NEW'
            )
            /
            NULLIF(
                SUM(valid_response_count) FILTER (
                    WHERE survey_version = 'NEW'
                ),
                0
            ),
            4
        ) AS weighted_new_average,

        MIN(minimum_rating) AS overall_minimum_rating,
        MAX(maximum_rating) AS overall_maximum_rating,

        COUNT(*) FILTER (
            WHERE minimum_rating < 1
               OR maximum_rating > 5
        )::bigint AS out_of_range_summary_rows

    FROM question_summary
),

toggle_summary AS (
    SELECT
        COUNT(*) FILTER (
            WHERE old_question_rows > 0
              AND new_question_rows = 0
        )::bigint AS courses_with_old_only,

        COUNT(*) FILTER (
            WHERE old_question_rows = 0
              AND new_question_rows > 0
        )::bigint AS courses_with_new_only,

        COUNT(*) FILTER (
            WHERE old_question_rows > 0
              AND new_question_rows > 0
        )::bigint AS courses_with_both_instruments

    FROM instrument_course_profile
),

course_term_overlap AS (
    SELECT
        COUNT(*) FILTER (
            WHERE instrument_count > 1
        )::bigint AS course_terms_with_both_instruments

    FROM instrument_course_term_profile
),

asci_ranked_terms AS (
    SELECT
        survey_version,
        term_id,
        term_code,
        term_label,

        ROW_NUMBER() OVER (
            PARTITION BY survey_version
            ORDER BY
                CASE
                    WHEN term_code ~ '^[0-9]+$'
                    THEN term_code::integer
                    ELSE NULL
                END DESC,
                term_code DESC
        ) AS term_rank

    FROM (
        SELECT DISTINCT
            survey_version,
            term_id,
            term_code,
            term_label

        FROM question_summary

        WHERE course_id =
            '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid
    ) terms
),

asci_latest_question_rows AS (
    SELECT
        q.survey_version,
        q.term_code,
        q.term_label,
        q.question_number,
        q.question_code,
        q.question_title,
        q.valid_response_count,
        q.average_rating,
        q.minimum_rating,
        q.maximum_rating

    FROM question_summary q

    JOIN asci_ranked_terms r
        ON r.survey_version = q.survey_version
       AND r.term_id = q.term_id
       AND r.term_rank = 1

    WHERE q.course_id =
        '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid
),

asci_acceptance AS (
    SELECT
        survey_version,
        term_code,
        term_label,

        COUNT(*)::bigint AS question_rows,

        JSONB_AGG(
            JSONB_BUILD_OBJECT(
                'question_code',
                question_code,

                'question_title',
                question_title,

                'valid_response_count',
                valid_response_count,

                'average_rating',
                average_rating,

                'minimum_rating',
                minimum_rating,

                'maximum_rating',
                maximum_rating
            )

            ORDER BY question_number
        ) AS question_results

    FROM asci_latest_question_rows

    GROUP BY
        survey_version,
        term_code,
        term_label
),

asci_json AS (
    SELECT
        COALESCE(
            JSONB_AGG(
                JSONB_BUILD_OBJECT(
                    'survey_version',
                    survey_version,

                    'term_code',
                    term_code,

                    'term_label',
                    term_label,

                    'question_rows',
                    question_rows,

                    'question_results',
                    question_results
                )

                ORDER BY
                    CASE
                        WHEN survey_version = 'NEW'
                        THEN 1
                        ELSE 2
                    END
            ),
            '[]'::jsonb
        ) AS asci_254_latest_instruments

    FROM asci_acceptance
)

SELECT
    g.question_summary_rows,
    g.represented_courses,
    g.represented_terms,
    g.course_term_instrument_groups,

    g.old_question_summary_rows,
    g.new_question_summary_rows,

    g.old_question_count,
    g.new_question_count,

    g.old_valid_question_responses,
    g.new_valid_question_responses,

    g.weighted_old_average,
    g.weighted_new_average,

    g.overall_minimum_rating,
    g.overall_maximum_rating,
    g.out_of_range_summary_rows,

    t.courses_with_old_only,
    t.courses_with_new_only,
    t.courses_with_both_instruments,

    o.course_terms_with_both_instruments,

    a.asci_254_latest_instruments

FROM global_summary g
CROSS JOIN toggle_summary t
CROSS JOIN course_term_overlap o
CROSS JOIN asci_json a;
