/*
    STUDENT SURVEY QUESTION-LEVEL REPORTING
    AUDIT-ENABLED ROLLBACK REHEARSAL

    Target grain:
      course_id + term_id + survey_version + question_code

    This rehearsal creates the reporting and API tables, validates them,
    updates an audit row, displays acceptance evidence, and ROLLS BACK.
*/

\set ON_ERROR_STOP on
\timing on
\pset pager off

BEGIN;

SET LOCAL application_name = 'student_survey_question_summary_rehearsal';
SET LOCAL work_mem = '128MB';
SET LOCAL jit = off;
SET LOCAL statement_timeout = '15min';

DO $preflight$
BEGIN
    IF to_regclass('reporting.course_student_survey_question_summary') IS NOT NULL
       OR to_regclass('reporting.course_student_survey_question_summary_api') IS NOT NULL
    THEN
        RAISE EXCEPTION
            'Preflight failed: target question-level reporting objects already exist.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM reporting.projection_refresh_run
        WHERE projection_name = 'course_student_survey_question_summary'
    )
    THEN
        RAISE EXCEPTION
            'Preflight failed: audit history already exists for course_student_survey_question_summary.';
    END IF;
END
$preflight$;

CREATE TEMP TABLE student_survey_question_refresh_context
ON COMMIT DROP AS
SELECT
    gen_random_uuid() AS run_id,
    CURRENT_TIMESTAMP AS report_as_of_utc;

INSERT INTO reporting.projection_refresh_run (
    run_id,
    projection_name,
    started_at,
    completed_at,
    source_filter,
    source_state,
    source_row_count,
    rows_inserted,
    rows_updated,
    rows_deleted,
    rows_unchanged,
    business_checksum,
    status,
    notes,
    error_information
)
SELECT
    run_id,
    'course_student_survey_question_summary',
    report_as_of_utc,
    NULL,
    jsonb_build_object(
        'instruments', jsonb_build_array('OLD', 'NEW'),
        'old_questions', 23,
        'new_questions', 11,
        'rating_minimum', 1,
        'rating_maximum', 5,
        'old_q15_zero_rule', 'exclude_out_of_range_source_value'
    ),
    jsonb_build_object(
        'committed_student_survey_summary_rows', 5809,
        'expected_question_rows', 120635,
        'expected_old_question_rows', 108744,
        'expected_new_question_rows', 11891
    ),
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    'STARTED',
    'Rollback rehearsal for additive Student Survey question-level projection.',
    NULL
FROM student_survey_question_refresh_context;

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

CREATE TABLE reporting.course_student_survey_question_summary AS
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

ALTER TABLE reporting.course_student_survey_question_summary
    ALTER COLUMN course_id SET NOT NULL,
    ALTER COLUMN term_id SET NOT NULL,
    ALTER COLUMN term_code SET NOT NULL,
    ALTER COLUMN course_code SET NOT NULL,
    ALTER COLUMN course_title SET NOT NULL,
    ALTER COLUMN college_name SET NOT NULL,
    ALTER COLUMN department_name SET NOT NULL,
    ALTER COLUMN survey_version SET NOT NULL,
    ALTER COLUMN question_number SET NOT NULL,
    ALTER COLUMN question_code SET NOT NULL,
    ALTER COLUMN question_title SET NOT NULL,
    ALTER COLUMN valid_response_count SET NOT NULL,
    ALTER COLUMN report_refresh_run_id SET NOT NULL,
    ALTER COLUMN report_as_of_utc SET NOT NULL,
    ALTER COLUMN business_row_hash SET NOT NULL;

ALTER TABLE reporting.course_student_survey_question_summary
    ADD CONSTRAINT course_student_survey_question_summary_pkey
    PRIMARY KEY (course_id, term_id, survey_version, question_code);

ALTER TABLE reporting.course_student_survey_question_summary
    ADD CONSTRAINT ck_course_student_survey_question_summary_values
    CHECK (
        survey_version IN ('OLD', 'NEW')
        AND valid_response_count >= 0
        AND (
            (valid_response_count = 0
             AND average_rating IS NULL
             AND minimum_rating IS NULL
             AND maximum_rating IS NULL)
            OR
            (valid_response_count > 0
             AND average_rating BETWEEN 1 AND 5
             AND minimum_rating BETWEEN 1 AND 5
             AND maximum_rating BETWEEN 1 AND 5
             AND minimum_rating <= average_rating
             AND average_rating <= maximum_rating)
        )
    );

CREATE INDEX course_student_survey_question_summary_course_code_idx
    ON reporting.course_student_survey_question_summary (course_code);

CREATE INDEX course_student_survey_question_summary_term_code_idx
    ON reporting.course_student_survey_question_summary (term_code);

CREATE INDEX course_student_survey_question_summary_lookup_idx
    ON reporting.course_student_survey_question_summary
        (course_id, survey_version, term_code, question_number);

CREATE TABLE reporting.course_student_survey_question_summary_api AS
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
    question_number,
    question_code,
    question_title,
    valid_response_count,
    average_rating,
    minimum_rating,
    maximum_rating,
    report_refresh_run_id,
    report_as_of_utc,
    MD5(
        course_id::text || ':' ||
        term_id::text || ':' ||
        survey_version || ':' ||
        question_code
    )::uuid AS student_survey_question_summary_id
FROM reporting.course_student_survey_question_summary;

ALTER TABLE reporting.course_student_survey_question_summary_api
    ALTER COLUMN student_survey_question_summary_id SET NOT NULL;

ALTER TABLE reporting.course_student_survey_question_summary_api
    ADD CONSTRAINT course_student_survey_question_summary_api_pkey
    PRIMARY KEY (student_survey_question_summary_id);

ALTER TABLE reporting.course_student_survey_question_summary_api
    ADD CONSTRAINT course_student_survey_question_summary_api_business_key
    UNIQUE (course_id, term_id, survey_version, question_code);

CREATE INDEX course_student_survey_question_summary_api_course_idx
    ON reporting.course_student_survey_question_summary_api
        (course_id, survey_version, term_code, question_number);

DO $validate$
DECLARE
    v_rows bigint;
    v_courses bigint;
    v_terms bigint;
    v_groups bigint;
    v_old_rows bigint;
    v_new_rows bigint;
    v_old_questions bigint;
    v_new_questions bigint;
    v_minimum numeric;
    v_maximum numeric;
    v_invalid bigint;
    v_zero_rows bigint;
    v_old_only bigint;
    v_new_only bigint;
    v_both bigint;
    v_mixed_terms bigint;
    v_api_rows bigint;
    v_api_ids bigint;
    v_api_keys bigint;
    v_asci_new_rows bigint;
    v_asci_old_rows bigint;
    v_asci_new_term text;
    v_asci_old_term text;
    v_airm_rows bigint;
    v_airm_zero_rows bigint;
BEGIN
    SELECT
        COUNT(*),
        COUNT(DISTINCT course_id),
        COUNT(DISTINCT term_id),
        COUNT(DISTINCT course_id::text || ':' || term_id::text || ':' || survey_version),
        COUNT(*) FILTER (WHERE survey_version = 'OLD'),
        COUNT(*) FILTER (WHERE survey_version = 'NEW'),
        COUNT(DISTINCT question_code) FILTER (WHERE survey_version = 'OLD'),
        COUNT(DISTINCT question_code) FILTER (WHERE survey_version = 'NEW'),
        MIN(minimum_rating),
        MAX(maximum_rating),
        COUNT(*) FILTER (
            WHERE valid_response_count < 0
               OR average_rating NOT BETWEEN 1 AND 5
               OR minimum_rating NOT BETWEEN 1 AND 5
               OR maximum_rating NOT BETWEEN 1 AND 5
               OR (valid_response_count = 0 AND (
                    average_rating IS NOT NULL
                    OR minimum_rating IS NOT NULL
                    OR maximum_rating IS NOT NULL
               ))
               OR (valid_response_count > 0 AND (
                    average_rating IS NULL
                    OR minimum_rating IS NULL
                    OR maximum_rating IS NULL
               ))
        ),
        COUNT(*) FILTER (WHERE valid_response_count = 0)
    INTO
        v_rows, v_courses, v_terms, v_groups,
        v_old_rows, v_new_rows,
        v_old_questions, v_new_questions,
        v_minimum, v_maximum, v_invalid, v_zero_rows
    FROM reporting.course_student_survey_question_summary;

    WITH course_profile AS (
        SELECT
            course_id,
            BOOL_OR(survey_version = 'OLD') AS has_old,
            BOOL_OR(survey_version = 'NEW') AS has_new
        FROM reporting.course_student_survey_question_summary
        GROUP BY course_id
    )
    SELECT
        COUNT(*) FILTER (WHERE has_old AND NOT has_new),
        COUNT(*) FILTER (WHERE NOT has_old AND has_new),
        COUNT(*) FILTER (WHERE has_old AND has_new)
    INTO v_old_only, v_new_only, v_both
    FROM course_profile;

    WITH term_profile AS (
        SELECT
            course_id,
            term_id,
            COUNT(DISTINCT survey_version) AS instrument_count
        FROM reporting.course_student_survey_question_summary
        GROUP BY course_id, term_id
    )
    SELECT COUNT(*) FILTER (WHERE instrument_count > 1)
    INTO v_mixed_terms
    FROM term_profile;

    SELECT
        COUNT(*),
        COUNT(DISTINCT student_survey_question_summary_id),
        COUNT(DISTINCT course_id::text || ':' || term_id::text || ':' || survey_version || ':' || question_code)
    INTO v_api_rows, v_api_ids, v_api_keys
    FROM reporting.course_student_survey_question_summary_api;

    SELECT COUNT(*), MIN(term_code)
    INTO v_asci_new_rows, v_asci_new_term
    FROM reporting.course_student_survey_question_summary
    WHERE course_id = '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid
      AND survey_version = 'NEW'
      AND term_code = '2967';

    SELECT COUNT(*), MIN(term_code)
    INTO v_asci_old_rows, v_asci_old_term
    FROM reporting.course_student_survey_question_summary
    WHERE course_id = '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid
      AND survey_version = 'OLD'
      AND term_code = '2899';

    SELECT
        COUNT(*),
        COUNT(*) FILTER (
            WHERE valid_response_count = 0
              AND average_rating IS NULL
              AND minimum_rating IS NULL
              AND maximum_rating IS NULL
        )
    INTO v_airm_rows, v_airm_zero_rows
    FROM reporting.course_student_survey_question_summary
    WHERE course_id = '580d0d70-f21e-462e-b606-6d07d5d04190'::uuid
      AND survey_version = 'NEW'
      AND term_code = '2943';

    IF v_rows <> 120635
       OR v_courses <> 404
       OR v_terms <> 59
       OR v_groups <> 5809
       OR v_old_rows <> 108744
       OR v_new_rows <> 11891
       OR v_old_questions <> 23
       OR v_new_questions <> 11
       OR v_minimum <> 1
       OR v_maximum <> 5
       OR v_invalid <> 0
       OR v_old_only <> 27
       OR v_new_only <> 30
       OR v_both <> 347
       OR v_mixed_terms <> 0
       OR v_api_rows <> 120635
       OR v_api_ids <> 120635
       OR v_api_keys <> 120635
       OR v_asci_new_rows <> 11
       OR v_asci_new_term <> '2967'
       OR v_asci_old_rows <> 23
       OR v_asci_old_term <> '2899'
       OR v_airm_rows <> 11
       OR v_airm_zero_rows <> 11
    THEN
        RAISE EXCEPTION
            'Question projection validation failed: rows=%, courses=%, terms=%, groups=%, old_rows=%, new_rows=%, old_questions=%, new_questions=%, min=%, max=%, invalid=%, zero_rows=%, old_only=%, new_only=%, both=%, mixed_terms=%, api_rows=%, api_ids=%, api_keys=%, ASCI_NEW_rows=%, ASCI_NEW_term=%, ASCI_OLD_rows=%, ASCI_OLD_term=%, AIRM_rows=%, AIRM_zero_rows=%',
            v_rows, v_courses, v_terms, v_groups,
            v_old_rows, v_new_rows, v_old_questions, v_new_questions,
            v_minimum, v_maximum, v_invalid, v_zero_rows,
            v_old_only, v_new_only, v_both, v_mixed_terms,
            v_api_rows, v_api_ids, v_api_keys,
            v_asci_new_rows, v_asci_new_term,
            v_asci_old_rows, v_asci_old_term,
            v_airm_rows, v_airm_zero_rows;
    END IF;
END
$validate$;

UPDATE reporting.projection_refresh_run r
SET
    completed_at = CURRENT_TIMESTAMP,
    source_row_count = 181375,
    rows_inserted = 120635,
    rows_updated = 0,
    rows_deleted = 0,
    rows_unchanged = 0,
    business_checksum = checksum_data.business_checksum,
    status = 'COMPLETED',
    notes = 'Student Survey question-level rollback rehearsal completed and reconciled.',
    error_information = NULL
FROM student_survey_question_refresh_context ctx
CROSS JOIN LATERAL (
    SELECT
        MD5(
            STRING_AGG(
                s.business_row_hash,
                ''
                ORDER BY
                    s.course_id,
                    s.term_id,
                    s.survey_version,
                    s.question_number
            )
        ) AS business_checksum
    FROM reporting.course_student_survey_question_summary s
) checksum_data
WHERE r.run_id = ctx.run_id;

SELECT
    COUNT(*)::bigint AS question_summary_rows,
    COUNT(DISTINCT course_id)::bigint AS represented_courses,
    COUNT(DISTINCT term_id)::bigint AS represented_terms,
    COUNT(*) FILTER (WHERE survey_version = 'OLD')::bigint AS old_question_rows,
    COUNT(*) FILTER (WHERE survey_version = 'NEW')::bigint AS new_question_rows,
    COUNT(*) FILTER (WHERE valid_response_count = 0)::bigint AS no_data_question_rows,
    MIN(minimum_rating) AS minimum_rating,
    MAX(maximum_rating) AS maximum_rating
FROM reporting.course_student_survey_question_summary;

SELECT
    run_id,
    projection_name,
    source_row_count,
    rows_inserted,
    business_checksum,
    status
FROM reporting.projection_refresh_run
WHERE run_id = (
    SELECT run_id
    FROM student_survey_question_refresh_context
);

SELECT
    term_code,
    term_label,
    survey_version,
    question_number,
    question_code,
    question_title,
    valid_response_count,
    average_rating,
    minimum_rating,
    maximum_rating
FROM reporting.course_student_survey_question_summary
WHERE course_id = '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid
  AND (
      (survey_version = 'NEW' AND term_code = '2967')
      OR
      (survey_version = 'OLD' AND term_code = '2899')
  )
ORDER BY
    CASE WHEN survey_version = 'NEW' THEN 1 ELSE 2 END,
    question_number;

SELECT
    term_code,
    term_label,
    survey_version,
    question_number,
    question_code,
    valid_response_count,
    average_rating,
    minimum_rating,
    maximum_rating
FROM reporting.course_student_survey_question_summary
WHERE course_id = '580d0d70-f21e-462e-b606-6d07d5d04190'::uuid
  AND survey_version = 'NEW'
  AND term_code = '2943'
ORDER BY question_number;

SELECT
    COUNT(*) AS target_tables_visible_inside_transaction
FROM information_schema.tables
WHERE table_schema = 'reporting'
  AND table_name IN (
      'course_student_survey_question_summary',
      'course_student_survey_question_summary_api'
  );

COMMIT;

SELECT
    COUNT(*) AS target_tables_visible_after_rollback
FROM information_schema.tables
WHERE table_schema = 'reporting'
  AND table_name IN (
      'course_student_survey_question_summary',
      'course_student_survey_question_summary_api'
  );

SELECT
    COUNT(*) AS audit_rows_visible_after_rollback
FROM reporting.projection_refresh_run
WHERE projection_name = 'course_student_survey_question_summary';
