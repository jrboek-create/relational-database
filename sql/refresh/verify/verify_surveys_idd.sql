\set ON_ERROR_STOP on
BEGIN;
\echo '### BUILD course_faculty_survey_summary'
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
\echo '### COMPARE course_faculty_survey_summary (all columns except run id and as-of time; all should be 0)'
SELECT (SELECT count(*) FROM tmp_course_faculty_survey_summary) AS rebuilt_rows, (SELECT count(*) FROM reporting.course_faculty_survey_summary) AS live_rows, (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, faculty_response_count, old_response_count, new_response_count, teaching_response_count, average_teaching_experience, quality_response_count, average_course_quality, business_row_hash FROM tmp_course_faculty_survey_summary EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, faculty_response_count, old_response_count, new_response_count, teaching_response_count, average_teaching_experience, quality_response_count, average_course_quality, business_row_hash FROM reporting.course_faculty_survey_summary) x) AS only_in_rebuilt, (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, faculty_response_count, old_response_count, new_response_count, teaching_response_count, average_teaching_experience, quality_response_count, average_course_quality, business_row_hash FROM reporting.course_faculty_survey_summary EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, faculty_response_count, old_response_count, new_response_count, teaching_response_count, average_teaching_experience, quality_response_count, average_course_quality, business_row_hash FROM tmp_course_faculty_survey_summary) x) AS only_in_live;
SELECT count(*) AS api_rows_joined, count(*) FILTER (WHERE a.faculty_survey_summary_id = md5(n.course_id::text || ':' || n.term_id::text)::uuid) AS api_id_match FROM tmp_course_faculty_survey_summary n JOIN reporting.course_faculty_survey_summary_api a ON a.faculty_survey_summary_id = md5(n.course_id::text || ':' || n.term_id::text)::uuid;
\echo '### BUILD course_student_survey_summary'
CREATE TEMP TABLE student_survey_refresh_context
ON COMMIT DROP
AS
SELECT
    gen_random_uuid() AS run_id,
    CURRENT_TIMESTAMP AS report_as_of_utc;
CREATE TEMP TABLE tmp_course_student_survey_summary AS
WITH all_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        'NEW'::text AS survey_version,
        source_row_number,
        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id,
        NULLIF(BTRIM(c0029), '') AS teaching_effectiveness,
        NULLIF(BTRIM(c0035), '') AS version_specific_rating
    FROM staging.raw_master_online_new_s02_spots_3caa2498

    UNION ALL

    SELECT
        2,
        34,
        'NEW'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0029), ''),
        NULLIF(BTRIM(c0035), '')
    FROM staging.raw_master_online_new_s01_rawdata_3caa2498

    UNION ALL

    SELECT
        3,
        37,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_31fb6e24

    UNION ALL

    SELECT
        4,
        40,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_3417e822

    UNION ALL

    SELECT
        5,
        41,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_324dd997

    UNION ALL

    SELECT
        6,
        42,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')
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
        component_id,
        survey_version,
        source_row_number,
        response_id,
        course_code,
        unique_id,
        teaching_effectiveness,
        version_specific_rating
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
        component_id,
        survey_version,
        source_row_number,
        response_id,

        SPLIT_PART(unique_id, '_', 1) AS term_code,

        UPPER(
            REGEXP_REPLACE(
                course_code,
                '[^A-Za-z0-9]',
                '',
                'g'
            )
        )
        || '_'
        || SPLIT_PART(unique_id, '_', 5)
            AS candidate_source_identifier,

        CASE
            WHEN teaching_effectiveness IN ('1','2','3','4','5')
            THEN teaching_effectiveness::integer
            ELSE NULL
        END AS teaching_effectiveness_rating,

        CASE
            WHEN version_specific_rating IN ('1','2','3','4','5')
            THEN version_specific_rating::integer
            ELSE NULL
        END AS version_specific_rating

    FROM deduplicated_responses
),

matched_responses AS (
    SELECT
        n.component_id,
        n.survey_version,
        n.source_row_number,
        n.response_id,
        n.teaching_effectiveness_rating,

        CASE
            WHEN n.survey_version = 'OLD'
            THEN n.version_specific_rating
            ELSE NULL
        END AS course_quality_rating,

        CASE
            WHEN n.survey_version = 'NEW'
            THEN n.version_specific_rating
            ELSE NULL
        END AS course_recommendation_rating,

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

course_term_summary AS (
    SELECT
        course_id,
        term_id,

        COUNT(*)::bigint AS student_response_count,

        SUM(
            CASE WHEN survey_version = 'OLD'
            THEN 1 ELSE 0 END
        )::bigint AS old_response_count,

        SUM(
            CASE WHEN survey_version = 'NEW'
            THEN 1 ELSE 0 END
        )::bigint AS new_response_count,

        SUM(
            CASE WHEN teaching_effectiveness_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS teaching_response_count,

        ROUND(
            AVG(teaching_effectiveness_rating),
            4
        ) AS average_teaching_effectiveness,

        SUM(
            CASE WHEN course_quality_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS course_quality_response_count,

        ROUND(
            AVG(course_quality_rating),
            4
        ) AS average_course_quality,

        SUM(
            CASE WHEN course_recommendation_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS course_recommendation_response_count,

        ROUND(
            AVG(course_recommendation_rating),
            4
        ) AS average_course_recommendation

    FROM matched_responses

    GROUP BY
        course_id,
        term_id
)
SELECT
    s.course_id,
    s.term_id,
    t.term_code,
    t.term_label,
    d.university_course_id,
    d.course_code,
    d.course_title,
    d.college_name,
    d.department_name,

    CASE
        WHEN s.old_response_count > 0
        THEN 'OLD'
        WHEN s.new_response_count > 0
        THEN 'NEW'
        ELSE NULL
    END AS survey_version,

    s.student_response_count,
    s.old_response_count,
    s.new_response_count,

    s.teaching_response_count,
    s.average_teaching_effectiveness,

    s.course_quality_response_count,
    s.average_course_quality,

    s.course_recommendation_response_count,
    s.average_course_recommendation,

    ctx.run_id AS report_refresh_run_id,
    ctx.report_as_of_utc,

    MD5(
        CONCAT_WS(
            '|',
            s.course_id::text,
            s.term_id::text,
            t.term_code,
            COALESCE(t.term_label, ''),
            d.university_course_id,
            d.course_code,
            d.course_title,
            d.college_name,
            d.department_name,

            CASE
                WHEN s.old_response_count > 0
                THEN 'OLD'
                WHEN s.new_response_count > 0
                THEN 'NEW'
                ELSE ''
            END,

            s.student_response_count::text,
            s.old_response_count::text,
            s.new_response_count::text,

            s.teaching_response_count::text,
            COALESCE(
                s.average_teaching_effectiveness::text,
                ''
            ),

            s.course_quality_response_count::text,
            COALESCE(
                s.average_course_quality::text,
                ''
            ),

            s.course_recommendation_response_count::text,
            COALESCE(
                s.average_course_recommendation::text,
                ''
            )
        )
    ) AS business_row_hash

FROM course_term_summary s

JOIN core.term t
    ON t.term_id = s.term_id

JOIN reporting.course_catalog_detail d
    ON d.course_id = s.course_id

CROSS JOIN student_survey_refresh_context ctx;
\echo '### COMPARE course_student_survey_summary (all columns except run id and as-of time; all should be 0)'
SELECT (SELECT count(*) FROM tmp_course_student_survey_summary) AS rebuilt_rows, (SELECT count(*) FROM reporting.course_student_survey_summary) AS live_rows, (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, student_response_count, old_response_count, new_response_count, teaching_response_count, average_teaching_effectiveness, course_quality_response_count, average_course_quality, course_recommendation_response_count, average_course_recommendation, business_row_hash FROM tmp_course_student_survey_summary EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, student_response_count, old_response_count, new_response_count, teaching_response_count, average_teaching_effectiveness, course_quality_response_count, average_course_quality, course_recommendation_response_count, average_course_recommendation, business_row_hash FROM reporting.course_student_survey_summary) x) AS only_in_rebuilt, (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, student_response_count, old_response_count, new_response_count, teaching_response_count, average_teaching_effectiveness, course_quality_response_count, average_course_quality, course_recommendation_response_count, average_course_recommendation, business_row_hash FROM reporting.course_student_survey_summary EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, student_response_count, old_response_count, new_response_count, teaching_response_count, average_teaching_effectiveness, course_quality_response_count, average_course_quality, course_recommendation_response_count, average_course_recommendation, business_row_hash FROM tmp_course_student_survey_summary) x) AS only_in_live;
SELECT count(*) AS api_rows_joined, count(*) FILTER (WHERE a.student_survey_summary_id = md5(n.course_id::text || ':' || n.term_id::text)::uuid) AS api_id_match FROM tmp_course_student_survey_summary n JOIN reporting.course_student_survey_summary_api a ON a.student_survey_summary_id = md5(n.course_id::text || ':' || n.term_id::text)::uuid;
\echo '### BUILD course_student_survey_question_summary'
SET LOCAL application_name = 'student_survey_question_summary_rehearsal';
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
\echo '### COMPARE course_student_survey_question_summary (all columns except run id and as-of time; all should be 0)'
SELECT (SELECT count(*) FROM tmp_course_student_survey_question_summary) AS rebuilt_rows, (SELECT count(*) FROM reporting.course_student_survey_question_summary) AS live_rows, (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, question_number, question_code, question_title, valid_response_count, average_rating, minimum_rating, maximum_rating, business_row_hash FROM tmp_course_student_survey_question_summary EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, question_number, question_code, question_title, valid_response_count, average_rating, minimum_rating, maximum_rating, business_row_hash FROM reporting.course_student_survey_question_summary) x) AS only_in_rebuilt, (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, question_number, question_code, question_title, valid_response_count, average_rating, minimum_rating, maximum_rating, business_row_hash FROM reporting.course_student_survey_question_summary EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, survey_version, question_number, question_code, question_title, valid_response_count, average_rating, minimum_rating, maximum_rating, business_row_hash FROM tmp_course_student_survey_question_summary) x) AS only_in_live;
SELECT count(*) AS api_rows_joined, count(*) FILTER (WHERE a.student_survey_question_summary_id = md5(n.course_id::text || ':' || n.term_id::text || ':' || n.survey_version || ':' || n.question_code)::uuid) AS api_id_match FROM tmp_course_student_survey_question_summary n JOIN reporting.course_student_survey_question_summary_api a ON a.student_survey_question_summary_id = md5(n.course_id::text || ':' || n.term_id::text || ':' || n.survey_version || ':' || n.question_code)::uuid;
\echo '### BUILD course_instructional_design_development_summary'
CREATE TEMP TABLE idd_build_context (
    run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL
) ON COMMIT DROP;
INSERT INTO idd_build_context (run_id, report_as_of_utc)
VALUES (gen_random_uuid(), clock_timestamp());
CREATE TEMP TABLE idd_candidate_source ON COMMIT DROP AS
WITH governed_source AS (
    SELECT
        s.source_hash,
        s.source_row_number,
        s.import_batch_id,
        s.imported_at,
        BTRIM(s.c0001) AS raw_course,
        BTRIM(s.c0002) AS raw_idd_term,
        NULLIF(BTRIM(s.c0003), '') AS project_type,
        NULLIF(BTRIM(s.c0004), '') AS source_college,
        BTRIM(s.c0005) AS project_status,
        NULLIF(BTRIM(s.c0006), '') AS days_late_after_course_copy,
        NULLIF(BTRIM(s.c0007), '') AS weeks_late_course_copy,
        NULLIF(BTRIM(s.c0008), '') AS course_developer,
        NULLIF(BTRIM(s.c0009), '') AS instructional_designer,
        NULLIF(BTRIM(s.c0010), '') AS notes,
        NULLIF(BTRIM(s.c0011), '') AS project_schedule_changes,
        NULLIF(BTRIM(s.c0012), '') AS major_side_project_type,
        NULLIF(BTRIM(s.c0013), '') AS important_project_dates,
        NULLIF(BTRIM(s.c0014), '') AS project_finished_date_raw,
        NULLIF(BTRIM(s.c0015), '') AS developer_completion_date_raw,
        NULLIF(BTRIM(s.c0016), '') AS days_past_contract_due_date,
        NULLIF(BTRIM(s.c0017), '') AS weeks_past_contract_due_date,
        NULLIF(BTRIM(s.c0018), '') AS course_delayed_reason,
        NULLIF(BTRIM(s.c0019), '') AS kickoff_info_needed,
        NULLIF(BTRIM(s.c0020), '') AS eoc_feedback,
        NULLIF(BTRIM(s.c0021), '') AS contract,
        NULLIF(BTRIM(s.c0022), '') AS supplemental_pay_request,
        NULLIF(BTRIM(s.c0023), '') AS snapgen_notes,
        NULLIF(BTRIM(s.c0024), '') AS snapgen_section_count,
        NULLIF(BTRIM(s.c0025), '') AS snapgen_sections_released,
        BTRIM(s.c0026)::numeric AS modified_serial,
        NULLIF(BTRIM(s.c0027), '') AS modified_by,
        NULLIF(BTRIM(s.c0028), '') AS hide_project,
        SUBSTRING(BTRIM(s.c0002) FROM '^([0-9]{4})') AS idd_year,
        SUBSTRING(
            BTRIM(s.c0002)
            FROM '^[0-9]{4}[[:space:]]+([0-9]{2})'
        ) AS idd_month,
        UPPER(
            SUBSTRING(
                BTRIM(s.c0001)
                FROM '^([A-Za-z]{2,}[[:space:]]+[0-9A-Za-z-]+)'
            )
        ) AS extracted_course_code
    FROM staging.raw_master_idd_product_s02_idd_prod_schd_40a4d388 AS s
    WHERE NULLIF(BTRIM(s.c0001), '') IS NOT NULL
      AND NULLIF(BTRIM(s.c0002), '') IS NOT NULL
      AND NULLIF(BTRIM(s.c0005), '') IS NOT NULL
      AND BTRIM(s.c0005) <> 'Project Status'
),
enrollment_terms AS (
    SELECT DISTINCT
        e.term_id,
        e.term_code,
        e.term_label,
        '20' || SUBSTRING(
            e.term_label
            FROM '^[A-Za-z]{3}_([0-9]{2})'
        ) AS term_year,
        CASE SUBSTRING(e.term_label FROM '^([A-Za-z]{3})_')
            WHEN 'Jan' THEN '01'
            WHEN 'Feb' THEN '02'
            WHEN 'Mar' THEN '03'
            WHEN 'Apr' THEN '04'
            WHEN 'May' THEN '05'
            WHEN 'Jun' THEN '06'
            WHEN 'Jul' THEN '07'
            WHEN 'Aug' THEN '08'
            WHEN 'Sep' THEN '09'
            WHEN 'Oct' THEN '10'
            WHEN 'Nov' THEN '11'
            WHEN 'Dec' THEN '12'
        END AS term_month
    FROM reporting.course_enrollment_summary AS e
),
reconciled AS (
    SELECT
        g.*,
        c.course_id,
        c.university_course_id,
        c.course_code,
        c.course_title,
        d.college_name,
        d.department_name,
        t.term_id,
        t.term_code,
        t.term_label,
        g.idd_year || '-' || g.idd_month AS idd_year_month,
        TIMESTAMP '1899-12-30'
            + g.modified_serial::double precision * INTERVAL '1 day'
            AS modified_timestamp
    FROM governed_source AS g
    LEFT JOIN reporting.course_current_catalog AS c
        ON UPPER(BTRIM(c.course_code)) = g.extracted_course_code
    LEFT JOIN reporting.course_catalog_detail AS d
        ON d.course_id = c.course_id
    LEFT JOIN enrollment_terms AS t
        ON t.term_year = g.idd_year
       AND t.term_month = g.idd_month
)
SELECT *
FROM reconciled;
CREATE TEMP TABLE tmp_course_instructional_design_development_summary (
    source_hash text NOT NULL,
    source_row_number bigint NOT NULL,
    import_batch_id uuid NOT NULL,
    source_imported_at timestamptz NOT NULL,

    course_id uuid NULL,
    university_course_id text NULL,
    course_code text NULL,
    course_title text NULL,
    college_name text NULL,
    department_name text NULL,

    raw_course text NOT NULL,
    extracted_course_code text NULL,
    catalog_match_status text NOT NULL,

    idd_year_month text NOT NULL,
    raw_idd_term text NOT NULL,
    term_id uuid NULL,
    term_code text NULL,
    term_label text NULL,
    institutional_term_match_status text NOT NULL,

    project_type text NULL,
    source_college text NULL,
    project_status text NOT NULL,
    course_developer text NULL,
    instructional_designer text NULL,
    notes text NULL,
    project_schedule_changes text NULL,
    major_side_project_type text NULL,
    important_project_dates text NULL,
    project_finished_date_raw text NULL,
    developer_completion_date_raw text NULL,
    days_late_after_course_copy text NULL,
    weeks_late_course_copy text NULL,
    days_past_contract_due_date text NULL,
    weeks_past_contract_due_date text NULL,
    course_delayed_reason text NULL,
    kickoff_info_needed text NULL,
    eoc_feedback text NULL,
    contract text NULL,
    supplemental_pay_request text NULL,
    snapgen_notes text NULL,
    snapgen_section_count text NULL,
    snapgen_sections_released text NULL,
    modified_timestamp timestamp without time zone NOT NULL,
    modified_by text NULL,
    hide_project text NULL,

    report_refresh_run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL,
    business_row_hash text NOT NULL,

    CONSTRAINT course_instructional_design_development_summary_pkey
        PRIMARY KEY (source_hash, source_row_number),
    CONSTRAINT ck_course_instructional_design_development_summary_status
        CHECK (
            project_status IN (
                'Completed',
                'Removed',
                'Moved to 2026-2027 Schedule',
                'Canceled',
                'Placeholder',
                'Not Started Yet',
                'In Progress'
            )
        ),
    CONSTRAINT ck_course_instructional_design_development_summary_catalog_match
        CHECK (
            (catalog_match_status = 'MATCHED' AND course_id IS NOT NULL)
            OR
            (catalog_match_status = 'UNMATCHED' AND course_id IS NULL)
        ),
    CONSTRAINT ck_course_instructional_design_development_summary_term_match
        CHECK (
            (
                institutional_term_match_status = 'MATCHED'
                AND term_id IS NOT NULL
                AND term_code IS NOT NULL
            )
            OR
            (
                institutional_term_match_status = 'UNMATCHED'
                AND term_id IS NULL
                AND term_code IS NULL
                AND term_label IS NULL
            )
        ),
    CONSTRAINT ck_course_instructional_design_development_summary_idd_month
        CHECK (idd_year_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$')
);
INSERT INTO tmp_course_instructional_design_development_summary (
    source_hash,
    source_row_number,
    import_batch_id,
    source_imported_at,
    course_id,
    university_course_id,
    course_code,
    course_title,
    college_name,
    department_name,
    raw_course,
    extracted_course_code,
    catalog_match_status,
    idd_year_month,
    raw_idd_term,
    term_id,
    term_code,
    term_label,
    institutional_term_match_status,
    project_type,
    source_college,
    project_status,
    course_developer,
    instructional_designer,
    notes,
    project_schedule_changes,
    major_side_project_type,
    important_project_dates,
    project_finished_date_raw,
    developer_completion_date_raw,
    days_late_after_course_copy,
    weeks_late_course_copy,
    days_past_contract_due_date,
    weeks_past_contract_due_date,
    course_delayed_reason,
    kickoff_info_needed,
    eoc_feedback,
    contract,
    supplemental_pay_request,
    snapgen_notes,
    snapgen_section_count,
    snapgen_sections_released,
    modified_timestamp,
    modified_by,
    hide_project,
    report_refresh_run_id,
    report_as_of_utc,
    business_row_hash
)
SELECT
    s.source_hash,
    s.source_row_number,
    s.import_batch_id,
    s.imported_at,
    s.course_id,
    s.university_course_id,
    s.course_code,
    s.course_title,
    s.college_name,
    s.department_name,
    s.raw_course,
    s.extracted_course_code,
    CASE WHEN s.course_id IS NOT NULL THEN 'MATCHED' ELSE 'UNMATCHED' END,
    s.idd_year_month,
    s.raw_idd_term,
    s.term_id,
    s.term_code,
    s.term_label,
    CASE WHEN s.term_id IS NOT NULL THEN 'MATCHED' ELSE 'UNMATCHED' END,
    s.project_type,
    s.source_college,
    s.project_status,
    s.course_developer,
    s.instructional_designer,
    s.notes,
    s.project_schedule_changes,
    s.major_side_project_type,
    s.important_project_dates,
    s.project_finished_date_raw,
    s.developer_completion_date_raw,
    s.days_late_after_course_copy,
    s.weeks_late_course_copy,
    s.days_past_contract_due_date,
    s.weeks_past_contract_due_date,
    s.course_delayed_reason,
    s.kickoff_info_needed,
    s.eoc_feedback,
    s.contract,
    s.supplemental_pay_request,
    s.snapgen_notes,
    s.snapgen_section_count,
    s.snapgen_sections_released,
    s.modified_timestamp,
    s.modified_by,
    s.hide_project,
    b.run_id,
    b.report_as_of_utc,
    MD5(
        CONCAT_WS(
            '|',
            s.source_hash,
            s.source_row_number::text,
            COALESCE(s.course_id::text, ''),
            COALESCE(s.term_id::text, ''),
            s.raw_course,
            s.raw_idd_term,
            COALESCE(s.project_type, ''),
            s.project_status,
            COALESCE(s.course_developer, ''),
            COALESCE(s.instructional_designer, ''),
            s.modified_timestamp::text
        )
    ) AS business_row_hash
FROM idd_candidate_source AS s
CROSS JOIN idd_build_context AS b;
\echo '### COMPARE course_instructional_design_development_summary (all columns except run id and as-of time; all should be 0)'
SELECT (SELECT count(*) FROM tmp_course_instructional_design_development_summary) AS rebuilt_rows, (SELECT count(*) FROM reporting.course_instructional_design_development_summary) AS live_rows, (SELECT count(*) FROM (SELECT source_hash, source_row_number, import_batch_id, source_imported_at, course_id, university_course_id, course_code, course_title, college_name, department_name, raw_course, extracted_course_code, catalog_match_status, idd_year_month, raw_idd_term, term_id, term_code, term_label, institutional_term_match_status, project_type, source_college, project_status, course_developer, instructional_designer, notes, project_schedule_changes, major_side_project_type, important_project_dates, project_finished_date_raw, developer_completion_date_raw, days_late_after_course_copy, weeks_late_course_copy, days_past_contract_due_date, weeks_past_contract_due_date, course_delayed_reason, kickoff_info_needed, eoc_feedback, contract, supplemental_pay_request, snapgen_notes, snapgen_section_count, snapgen_sections_released, modified_timestamp, modified_by, hide_project, business_row_hash FROM tmp_course_instructional_design_development_summary EXCEPT ALL SELECT source_hash, source_row_number, import_batch_id, source_imported_at, course_id, university_course_id, course_code, course_title, college_name, department_name, raw_course, extracted_course_code, catalog_match_status, idd_year_month, raw_idd_term, term_id, term_code, term_label, institutional_term_match_status, project_type, source_college, project_status, course_developer, instructional_designer, notes, project_schedule_changes, major_side_project_type, important_project_dates, project_finished_date_raw, developer_completion_date_raw, days_late_after_course_copy, weeks_late_course_copy, days_past_contract_due_date, weeks_past_contract_due_date, course_delayed_reason, kickoff_info_needed, eoc_feedback, contract, supplemental_pay_request, snapgen_notes, snapgen_section_count, snapgen_sections_released, modified_timestamp, modified_by, hide_project, business_row_hash FROM reporting.course_instructional_design_development_summary) x) AS only_in_rebuilt, (SELECT count(*) FROM (SELECT source_hash, source_row_number, import_batch_id, source_imported_at, course_id, university_course_id, course_code, course_title, college_name, department_name, raw_course, extracted_course_code, catalog_match_status, idd_year_month, raw_idd_term, term_id, term_code, term_label, institutional_term_match_status, project_type, source_college, project_status, course_developer, instructional_designer, notes, project_schedule_changes, major_side_project_type, important_project_dates, project_finished_date_raw, developer_completion_date_raw, days_late_after_course_copy, weeks_late_course_copy, days_past_contract_due_date, weeks_past_contract_due_date, course_delayed_reason, kickoff_info_needed, eoc_feedback, contract, supplemental_pay_request, snapgen_notes, snapgen_section_count, snapgen_sections_released, modified_timestamp, modified_by, hide_project, business_row_hash FROM reporting.course_instructional_design_development_summary EXCEPT ALL SELECT source_hash, source_row_number, import_batch_id, source_imported_at, course_id, university_course_id, course_code, course_title, college_name, department_name, raw_course, extracted_course_code, catalog_match_status, idd_year_month, raw_idd_term, term_id, term_code, term_label, institutional_term_match_status, project_type, source_college, project_status, course_developer, instructional_designer, notes, project_schedule_changes, major_side_project_type, important_project_dates, project_finished_date_raw, developer_completion_date_raw, days_late_after_course_copy, weeks_late_course_copy, days_past_contract_due_date, weeks_past_contract_due_date, course_delayed_reason, kickoff_info_needed, eoc_feedback, contract, supplemental_pay_request, snapgen_notes, snapgen_section_count, snapgen_sections_released, modified_timestamp, modified_by, hide_project, business_row_hash FROM tmp_course_instructional_design_development_summary) x) AS only_in_live;
ROLLBACK;
