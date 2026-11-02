-- Builds tmp_course_redeveloped_summary (a temporary table): one row per section on the "ReDev" sheet
-- (Redeveloped Courses MASTER.xlsx): instructor feedback on teaching a redeveloped course.
-- Linked through Sis Source Id (term_9W1_SUBJ_NUM_SECTION_...) to core.term and to the current catalog (course code,
-- spaces/case ignored). Instructor name, email and start time are deliberately NOT carried into reporting.
-- Columns are found through the staging column map by header name (the headers are long and contain odd spaces).

CREATE TEMP TABLE redeveloped_refresh_context ON COMMIT DROP AS
SELECT gen_random_uuid() AS run_id, CURRENT_TIMESTAMP AS report_as_of_utc;

CREATE TEMP TABLE tmp_course_redeveloped_summary ON COMMIT DROP AS
WITH colmap AS (
    SELECT REPLACE(BTRIM(m.source_header), chr(160), ' ') AS header, m.staged_column
    FROM staging._phase2_column_map m
    JOIN staging._phase2_components c USING (component_id)
    WHERE c.staging_table = 'raw_redeveloped_course_s01_redev_466db3fd'
),
cols AS (
    SELECT
        (SELECT staged_column FROM colmap WHERE header = 'Sis Source Id' LIMIT 1) AS sis,
        (SELECT staged_column FROM colmap WHERE header = 'Response Y/N' LIMIT 1) AS responded,
        (SELECT staged_column FROM colmap WHERE header = 'Completion time' LIMIT 1) AS completed,
        (SELECT staged_column FROM colmap WHERE header LIKE 'Helpfulness of information%' LIMIT 1) AS helpfulness,
        (SELECT staged_column FROM colmap WHERE header LIKE 'What would you have liked to know%' LIMIT 1) AS liked_to_know,
        (SELECT staged_column FROM colmap WHERE header LIKE 'Were there any significant%' LIMIT 1) AS changes,
        (SELECT staged_column FROM colmap WHERE header LIKE 'If "Yes" above%' LIMIT 1) AS changes_detail
),
src AS (
    SELECT r.source_hash, r.source_row_number,
           NULLIF(BTRIM(to_jsonb(r) ->> k.sis), '') AS sis_source_id,
           NULLIF(BTRIM(to_jsonb(r) ->> k.responded), '') AS response_text,
           NULLIF(BTRIM(to_jsonb(r) ->> k.completed), '') AS completed_raw,
           NULLIF(BTRIM(to_jsonb(r) ->> k.helpfulness), '') AS helpfulness_rating,
           NULLIF(BTRIM(to_jsonb(r) ->> k.liked_to_know), '') AS would_have_liked_to_know,
           NULLIF(BTRIM(to_jsonb(r) ->> k.changes), '') AS significant_changes,
           NULLIF(BTRIM(to_jsonb(r) ->> k.changes_detail), '') AS changes_detail
    FROM staging.raw_redeveloped_course_s01_redev_466db3fd r CROSS JOIN cols k
    WHERE r.source_row_number IS NOT NULL
),
parsed AS (
    SELECT s.*,
           SPLIT_PART(s.sis_source_id, '_', 1) AS term_code,
           UPPER(SPLIT_PART(s.sis_source_id, '_', 3) || SPLIT_PART(s.sis_source_id, '_', 4)) AS course_key,
           SPLIT_PART(s.sis_source_id, '_', 3) || ' ' || SPLIT_PART(s.sis_source_id, '_', 4) AS raw_course,
           SPLIT_PART(s.sis_source_id, '_', 5) AS section_identifier
    FROM src s
    WHERE s.sis_source_id ~ '^[0-9]+_[^_]+_[^_]+_[^_]+_[^_]+'
)
SELECT p.source_hash, p.source_row_number, p.sis_source_id,
       cat.course_id, cat.university_course_id, cat.course_code, cat.course_title, cat.college_name, cat.department_name,
       p.raw_course,
       CASE WHEN cat.course_id IS NULL THEN 'UNMATCHED' ELSE 'MATCHED' END AS catalog_match_status,
       t.term_id, p.term_code, t.term_label, p.section_identifier,
       (LOWER(p.response_text) = 'yes') AS responded,
       CASE WHEN p.completed_raw ~ '^[0-9]+(\.[0-9]+)?$'
            THEN (TIMESTAMP '1899-12-30' + p.completed_raw::numeric * INTERVAL '1 day')::date END AS response_date,
       p.helpfulness_rating, p.significant_changes, p.changes_detail, p.would_have_liked_to_know,
       ctx.run_id AS report_refresh_run_id,
       ctx.report_as_of_utc,
       md5(concat_ws('|', p.source_hash, p.source_row_number::text, p.sis_source_id, cat.course_id::text, t.term_id::text, p.response_text,
                     p.completed_raw, p.helpfulness_rating, p.significant_changes, p.changes_detail, p.would_have_liked_to_know)) AS business_row_hash
FROM parsed p
LEFT JOIN reporting.course_current_catalog_api cat ON UPPER(REPLACE(cat.course_code, ' ', '')) = p.course_key
LEFT JOIN (SELECT DISTINCT ON (term_code) term_code, term_id, term_label FROM core.term ORDER BY term_code, term_id) t ON t.term_code = p.term_code
CROSS JOIN redeveloped_refresh_context ctx;
