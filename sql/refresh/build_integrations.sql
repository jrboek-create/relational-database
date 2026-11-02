-- Builds tmp_course_integration_summary (a temporary table): one row per course and integration type from the
-- "Integrations" sheet (MASTER Integrations.xlsx). Each cell holds the month ('YYYY MM') or '.' for none.
-- The sheet's marker row (blank Course_Code, cells 'Last' or 'Start') says what each column's month means.
-- Columns are found through the staging column map, so no column positions are hard-coded.
-- Courses are linked to the current catalog by course code (spaces and case ignored); others are UNMATCHED.

CREATE TEMP TABLE integration_refresh_context ON COMMIT DROP AS
SELECT gen_random_uuid() AS run_id, CURRENT_TIMESTAMP AS report_as_of_utc;

CREATE TEMP TABLE tmp_course_integration_summary ON COMMIT DROP AS
WITH colmap AS (
    SELECT BTRIM(m.source_header) AS header, m.staged_column, m.column_ordinal
    FROM staging._phase2_column_map m
    JOIN staging._phase2_components c USING (component_id)
    WHERE c.staging_table = 'raw_master_integration_s01_integrations_1c657953'
),
code_col AS (SELECT staged_column FROM colmap WHERE header = 'Course_Code' LIMIT 1),
cells AS (
    SELECT r.source_hash, r.source_row_number,
           NULLIF(BTRIM(to_jsonb(r) ->> (SELECT staged_column FROM code_col)), '') AS raw_course,
           m.header AS integration_name, m.column_ordinal,
           NULLIF(BTRIM(to_jsonb(r) ->> m.staged_column), '') AS cell
    FROM staging.raw_master_integration_s01_integrations_1c657953 r
    CROSS JOIN colmap m
    WHERE r.source_row_number IS NOT NULL AND m.header <> 'Course_Code'
),
meaning AS (   -- from the marker row: blank course code, every cell 'Last' or 'Start'
    SELECT integration_name, MIN(LOWER(cell)) AS date_meaning
    FROM cells WHERE raw_course IS NULL AND LOWER(cell) IN ('last', 'start')
    GROUP BY integration_name
),
src AS (
    SELECT c.source_hash, c.source_row_number, c.raw_course, c.integration_name, c.column_ordinal,
           REPLACE(c.cell, ' ', '-') AS integration_month, COALESCE(mn.date_meaning, 'unknown') AS date_meaning
    FROM cells c LEFT JOIN meaning mn USING (integration_name)
    WHERE c.raw_course IS NOT NULL AND LOWER(c.raw_course) <> 'course_code'
      AND c.cell ~ '^[0-9]{4} (0[1-9]|1[0-2])$'
)
SELECT s.source_hash, s.source_row_number, s.integration_name, s.column_ordinal AS integration_order,
       cat.course_id, cat.university_course_id, cat.course_code, cat.course_title, cat.college_name, cat.department_name,
       s.raw_course,
       CASE WHEN cat.course_id IS NULL THEN 'UNMATCHED' ELSE 'MATCHED' END AS catalog_match_status,
       s.date_meaning, s.integration_month,
       ctx.run_id AS report_refresh_run_id,
       ctx.report_as_of_utc,
       md5(concat_ws('|', s.source_hash, s.source_row_number::text, s.integration_name, cat.course_id::text, s.raw_course,
                     s.date_meaning, s.integration_month)) AS business_row_hash
FROM src s
LEFT JOIN reporting.course_current_catalog_api cat ON UPPER(REPLACE(cat.course_code, ' ', '')) = UPPER(REPLACE(s.raw_course, ' ', ''))
CROSS JOIN integration_refresh_context ctx;
