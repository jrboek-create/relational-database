-- Builds tmp_course_student_survey_question_summary (a temporary table) using the original build logic from
-- student-survey-question-summary-persistent-build.sql (Oct 2026), extracted unchanged. Verified on 2 Nov 2026 to reproduce
-- reporting.course_student_survey_question_summary exactly on every column except run id and as-of time.

SET LOCAL work_mem = '128MB';

SET LOCAL jit = off;

SET LOCAL statement_timeout = '15min';

CREATE TEMP TABLE student_survey_question_refresh_context
ON COMMIT DROP AS
SELECT
    gen_random_uuid() AS run_id,
    CURRENT_TIMESTAMP AS report_as_of_utc;

CREATE TEMP TABLE student_survey_question_rating_summary
ON COMMIT DROP AS
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
        2, 34, source_row_number,
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
          'responseuniqueid', 'response unique id', 'response_id', 'responseid'
      )
      AND LOWER(BTRIM(unique_id)) <> 'uniqueid'
),
new_deduplicated AS (
    SELECT
        response_id, course_code, unique_id,
        q1, q2, q3, q4, q5, q6, q7, q9, q10, q11, q13
    FROM (
        SELECT
            n.*,
            ROW_NUMBER() OVER (
                PARTITION BY response_id
                ORDER BY source_priority, component_id, source_row_number
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
        o.course_id,
        n.q1, n.q2, n.q3, n.q4, n.q5, n.q6,
        n.q7, n.q9, n.q10, n.q11, n.q13
    FROM new_deduplicated n
    JOIN core.term t
      ON BTRIM(t.term_code) = SPLIT_PART(n.unique_id, '_', 1)
    JOIN core.course_offering_section o
      ON o.term_id = t.term_id
     AND UPPER(BTRIM(o.source_identifier)) =
         UPPER(REGEXP_REPLACE(n.course_code, '[^A-Za-z0-9]', '', 'g'))
         || '_'
         || SPLIT_PART(n.unique_id, '_', 5)
),
new_question_values AS (
    SELECT
        n.survey_version,
        n.response_id,
        n.course_id,
        n.term_id,
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
    ) q(question_number, question_code, raw_value)
    WHERE q.raw_value IN ('1', '2', '3', '4', '5')
),
old_source_rows AS (
    SELECT
        1 AS source_priority, 37 AS component_id, source_row_number,
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
        2, 40, source_row_number,
        NULLIF(BTRIM(c0001), ''), NULLIF(BTRIM(c0012), ''), NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0023), ''), NULLIF(BTRIM(c0024), ''), NULLIF(BTRIM(c0025), ''),
        NULLIF(BTRIM(c0026), ''), NULLIF(BTRIM(c0027), ''), NULLIF(BTRIM(c0028), ''),
        NULLIF(BTRIM(c0029), ''), NULLIF(BTRIM(c0030), ''), NULLIF(BTRIM(c0031), ''),
        NULLIF(BTRIM(c0033), ''), NULLIF(BTRIM(c0034), ''), NULLIF(BTRIM(c0036), ''),
        NULLIF(BTRIM(c0037), ''), NULLIF(BTRIM(c0038), ''), NULLIF(BTRIM(c0039), ''),
        NULLIF(BTRIM(c0041), ''), NULLIF(BTRIM(c0042), ''), NULLIF(BTRIM(c0043), ''),
        NULLIF(BTRIM(c0044), ''), NULLIF(BTRIM(c0045), ''), NULLIF(BTRIM(c0046), ''),
        NULLIF(BTRIM(c0048), ''), NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_3417e822

    UNION ALL

    SELECT
        3, 41, source_row_number,
        NULLIF(BTRIM(c0001), ''), NULLIF(BTRIM(c0012), ''), NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0023), ''), NULLIF(BTRIM(c0024), ''), NULLIF(BTRIM(c0025), ''),
        NULLIF(BTRIM(c0026), ''), NULLIF(BTRIM(c0027), ''), NULLIF(BTRIM(c0028), ''),
        NULLIF(BTRIM(c0029), ''), NULLIF(BTRIM(c0030), ''), NULLIF(BTRIM(c0031), ''),
        NULLIF(BTRIM(c0033), ''), NULLIF(BTRIM(c0034), ''), NULLIF(BTRIM(c0036), ''),
        NULLIF(BTRIM(c0037), ''), NULLIF(BTRIM(c0038), ''), NULLIF(BTRIM(c0039), ''),
        NULLIF(BTRIM(c0041), ''), NULLIF(BTRIM(c0042), ''), NULLIF(BTRIM(c0043), ''),
        NULLIF(BTRIM(c0044), ''), NULLIF(BTRIM(c0045), ''), NULLIF(BTRIM(c0046), ''),
        NULLIF(BTRIM(c0048), ''), NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_324dd997

    UNION ALL

    SELECT
        4, 42, source_row_number,
        NULLIF(BTRIM(c0001), ''), NULLIF(BTRIM(c0012), ''), NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0023), ''), NULLIF(BTRIM(c0024), ''), NULLIF(BTRIM(c0025), ''),
        NULLIF(BTRIM(c0026), ''), NULLIF(BTRIM(c0027), ''), NULLIF(BTRIM(c0028), ''),
        NULLIF(BTRIM(c0029), ''), NULLIF(BTRIM(c0030), ''), NULLIF(BTRIM(c0031), ''),
        NULLIF(BTRIM(c0033), ''), NULLIF(BTRIM(c0034), ''), NULLIF(BTRIM(c0036), ''),
        NULLIF(BTRIM(c0037), ''), NULLIF(BTRIM(c0038), ''), NULLIF(BTRIM(c0039), ''),
        NULLIF(BTRIM(c0041), ''), NULLIF(BTRIM(c0042), ''), NULLIF(BTRIM(c0043), ''),
        NULLIF(BTRIM(c0044), ''), NULLIF(BTRIM(c0045), ''), NULLIF(BTRIM(c0046), ''),
        NULLIF(BTRIM(c0048), ''), NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_6164ddea
),
old_valid_rows AS (
    SELECT *
    FROM old_source_rows
    WHERE response_id IS NOT NULL
      AND course_code IS NOT NULL
      AND unique_id IS NOT NULL
      AND LOWER(BTRIM(response_id)) NOT IN (
          'responseuniqueid', 'response unique id', 'response_id', 'responseid'
      )
      AND LOWER(BTRIM(unique_id)) <> 'uniqueid'
),
old_deduplicated AS (
    SELECT
        response_id, course_code, unique_id,
        q1, q2, q3, q4, q5, q6, q7, q8, q9, q11, q12,
        q14, q15, q16, q17, q19, q20, q21, q22, q23, q24, q26, q28
    FROM (
        SELECT
            o.*,
            ROW_NUMBER() OVER (
                PARTITION BY response_id
                ORDER BY source_priority, component_id, source_row_number
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
        s.course_id,
        o.q1, o.q2, o.q3, o.q4, o.q5, o.q6, o.q7, o.q8,
        o.q9, o.q11, o.q12, o.q14, o.q15, o.q16, o.q17,
        o.q19, o.q20, o.q21, o.q22, o.q23, o.q24, o.q26, o.q28
    FROM old_deduplicated o
    JOIN core.term t
      ON BTRIM(t.term_code) = SPLIT_PART(o.unique_id, '_', 1)
    JOIN core.course_offering_section s
      ON s.term_id = t.term_id
     AND UPPER(BTRIM(s.source_identifier)) =
         UPPER(REGEXP_REPLACE(o.course_code, '[^A-Za-z0-9]', '', 'g'))
         || '_'
         || SPLIT_PART(o.unique_id, '_', 5)
),
old_question_values AS (
    SELECT
        o.survey_version,
        o.response_id,
        o.course_id,
        o.term_id,
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
    ) q(question_number, question_code, raw_value)
    WHERE q.raw_value IN ('1', '2', '3', '4', '5')
),
all_question_values AS (
    SELECT * FROM new_question_values
    UNION ALL
    SELECT * FROM old_question_values
)
SELECT
    course_id,
    term_id,
    survey_version,
    question_number,
    question_code,
    COUNT(DISTINCT response_id)::bigint AS valid_response_count,
    ROUND(AVG(rating), 4) AS average_rating,
    MIN(rating) AS minimum_rating,
    MAX(rating) AS maximum_rating
FROM all_question_values
GROUP BY
    course_id,
    term_id,
    survey_version,
    question_number,
    question_code;

CREATE TEMP TABLE tmp_course_student_survey_question_summary AS
WITH instrument_question_set AS (
    SELECT *
    FROM (
        VALUES
            ('NEW'::text, 1,  'Q1'::text),
            ('NEW'::text, 2,  'Q2'::text),
            ('NEW'::text, 3,  'Q3'::text),
            ('NEW'::text, 4,  'Q4'::text),
            ('NEW'::text, 5,  'Q5'::text),
            ('NEW'::text, 6,  'Q6'::text),
            ('NEW'::text, 7,  'Q7'::text),
            ('NEW'::text, 9,  'Q9'::text),
            ('NEW'::text, 10, 'Q10'::text),
            ('NEW'::text, 11, 'Q11'::text),
            ('NEW'::text, 13, 'Q13'::text),
            ('OLD'::text, 1,  'Q1'::text),
            ('OLD'::text, 2,  'Q2'::text),
            ('OLD'::text, 3,  'Q3'::text),
            ('OLD'::text, 4,  'Q4'::text),
            ('OLD'::text, 5,  'Q5'::text),
            ('OLD'::text, 6,  'Q6'::text),
            ('OLD'::text, 7,  'Q7'::text),
            ('OLD'::text, 8,  'Q8'::text),
            ('OLD'::text, 9,  'Q9'::text),
            ('OLD'::text, 11, 'Q11'::text),
            ('OLD'::text, 12, 'Q12'::text),
            ('OLD'::text, 14, 'Q14'::text),
            ('OLD'::text, 15, 'Q15'::text),
            ('OLD'::text, 16, 'Q16'::text),
            ('OLD'::text, 17, 'Q17'::text),
            ('OLD'::text, 19, 'Q19'::text),
            ('OLD'::text, 20, 'Q20'::text),
            ('OLD'::text, 21, 'Q21'::text),
            ('OLD'::text, 22, 'Q22'::text),
            ('OLD'::text, 23, 'Q23'::text),
            ('OLD'::text, 24, 'Q24'::text),
            ('OLD'::text, 26, 'Q26'::text),
            ('OLD'::text, 28, 'Q28'::text)
    ) q(survey_version, question_number, question_code)
),
question_titles AS (
    SELECT
        'NEW'::text AS survey_version,
        REPLACE(BTRIM(c0001), 'Question ', '')::integer AS question_number,
        BTRIM(c0002) AS question_title
    FROM staging.raw_master_online_new_s03_questionmapper_3caa2498
    WHERE BTRIM(c0001) LIKE 'Question %'

    UNION ALL

    SELECT
        'OLD'::text,
        REPLACE(BTRIM(c0001), 'Question ', '')::integer,
        BTRIM(c0002)
    FROM staging.raw_master_online_part_s03_questionmapper_31fb6e24
    WHERE BTRIM(c0001) LIKE 'Question %'
),
instrument_history AS (
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
        survey_version
    FROM reporting.course_student_survey_summary
    WHERE student_response_count > 0
),
scaffold AS (
    SELECT
        h.course_id,
        h.term_id,
        h.term_code,
        h.term_label,
        h.university_course_id,
        h.course_code,
        h.course_title,
        h.college_name,
        h.department_name,
        h.survey_version,
        q.question_number,
        q.question_code,
        t.question_title
    FROM instrument_history h
    JOIN instrument_question_set q
      ON q.survey_version = h.survey_version
    JOIN question_titles t
      ON t.survey_version = q.survey_version
     AND t.question_number = q.question_number
)
SELECT
    s.course_id,
    s.term_id,
    s.term_code,
    s.term_label,
    s.university_course_id,
    s.course_code,
    s.course_title,
    s.college_name,
    s.department_name,
    s.survey_version,
    s.question_number,
    s.question_code,
    s.question_title,
    COALESCE(r.valid_response_count, 0)::bigint AS valid_response_count,
    r.average_rating,
    r.minimum_rating,
    r.maximum_rating,
    ctx.run_id AS report_refresh_run_id,
    ctx.report_as_of_utc,
    MD5(
        CONCAT_WS(
            '|',
            s.course_id::text,
            s.term_id::text,
            s.term_code,
            COALESCE(s.term_label, ''),
            COALESCE(s.university_course_id, ''),
            s.course_code,
            s.course_title,
            s.college_name,
            s.department_name,
            s.survey_version,
            s.question_number::text,
            s.question_code,
            s.question_title,
            COALESCE(r.valid_response_count, 0)::text,
            COALESCE(r.average_rating::text, ''),
            COALESCE(r.minimum_rating::text, ''),
            COALESCE(r.maximum_rating::text, '')
        )
    ) AS business_row_hash
FROM scaffold s
LEFT JOIN student_survey_question_rating_summary r
  ON r.course_id = s.course_id
 AND r.term_id = s.term_id
 AND r.survey_version = s.survey_version
 AND r.question_number = s.question_number
 AND r.question_code = s.question_code
CROSS JOIN student_survey_question_refresh_context ctx;
