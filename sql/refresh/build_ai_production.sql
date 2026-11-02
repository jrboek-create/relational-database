-- Builds tmp_course_ai_production_summary (a temporary table): one row per AI production project from the
-- "AI Prod Schd" sheet, linked to the current catalog by course code (spaces and case ignored).
-- Courses not in the current catalog are kept and marked UNMATCHED. ai_section_count = sections listed for
-- the course on the "AI Course List & Start Months" sheet. Header rows stored as data are skipped.

CREATE TEMP TABLE ai_production_refresh_context ON COMMIT DROP AS
SELECT gen_random_uuid() AS run_id, CURRENT_TIMESTAMP AS report_as_of_utc;

CREATE TEMP TABLE tmp_course_ai_production_summary ON COMMIT DROP AS
WITH src AS (
    SELECT source_hash, source_row_number,
           NULLIF(BTRIM(c0011), '') AS raw_course,
           NULLIF(BTRIM(c0001), '') AS source_college,
           NULLIF(BTRIM(c0002), '') AS implementation_label,
           NULLIF(BTRIM(c0003), '') AS project_name,
           NULLIF(BTRIM(c0004), '') AS ai_type,
           NULLIF(BTRIM(c0005), '') AS template_link,
           NULLIF(BTRIM(c0006), '') AS project_status,
           NULLIF(BTRIM(c0007), '') AS description,
           CASE WHEN BTRIM(c0008) ~ '^[0-9]{4} (0[1-9]|1[0-2])$' THEN REPLACE(BTRIM(c0008), ' ', '-') END AS implementation_month
    FROM staging.raw_master_ai_producti_s02_ai_prod_schd_142fe4ef
    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0011), '') IS NOT NULL
      AND LOWER(BTRIM(c0011)) <> 'course'
),
ai_sections AS (
    SELECT UPPER(REPLACE(BTRIM(c0003), ' ', '')) AS course_key, COUNT(DISTINCT BTRIM(c0002)) AS section_count
    FROM staging.raw_master_ai_producti_s05_ai_course_list_sta_142fe4ef
    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0002), '') IS NOT NULL
      AND LOWER(BTRIM(COALESCE(c0003, ''))) <> 'course code'
    GROUP BY 1
)
SELECT s.source_hash, s.source_row_number,
       c.course_id, c.university_course_id, c.course_code, c.course_title, c.college_name, c.department_name,
       s.raw_course,
       CASE WHEN c.course_id IS NULL THEN 'UNMATCHED' ELSE 'MATCHED' END AS catalog_match_status,
       s.implementation_month, s.implementation_label, s.project_name, s.ai_type, s.project_status, s.description,
       s.template_link, s.source_college,
       COALESCE(a.section_count, 0) AS ai_section_count,
       ctx.run_id AS report_refresh_run_id,
       ctx.report_as_of_utc,
       md5(concat_ws('|', s.source_hash, s.source_row_number::text, c.course_id::text, s.raw_course, s.implementation_month,
                     s.implementation_label, s.project_name, s.ai_type, s.project_status, s.description, s.template_link,
                     s.source_college, COALESCE(a.section_count, 0)::text)) AS business_row_hash
FROM src s
LEFT JOIN reporting.course_current_catalog_api c ON UPPER(REPLACE(c.course_code, ' ', '')) = UPPER(REPLACE(s.raw_course, ' ', ''))
LEFT JOIN ai_sections a ON a.course_key = UPPER(REPLACE(s.raw_course, ' ', ''))
CROSS JOIN ai_production_refresh_context ctx;
