-- Builds the Grades, Enrollment and DFWI summaries from the core tables into
-- temporary tables (tmp_grade_summary, tmp_enrollment_summary, tmp_dfwi_summary).
-- Rules reconstructed and verified on 2 Nov 2026 against the tables built 20 Oct 2026:
--   Grades:     core.grade per course + term, linked courses only (course_id not null).
--   Enrollment: core.course_offering_section per course + term, sections with an enrollment count only.
--   DFWI:       one row per enrollment row; D + F + W + I grades (WF excluded) over enrollment, rounded to 2 decimals.
--   Course and term labels come from reporting.course_current_catalog_api and core.term.

CREATE TEMP TABLE tmp_grade_summary ON COMMIT DROP AS
SELECT g.course_id, g.term_id, t.term_code, t.term_label,
       c.university_course_id, c.course_code, c.course_title, c.college_name, c.department_name,
       count(*) AS grade_count,
       count(g.final_score) AS scored_count,
       avg(g.final_score) AS average_final_score,
       count(*) FILTER (WHERE g.official_grade_code = 'A') AS grade_a_count,
       count(*) FILTER (WHERE g.official_grade_code = 'AU') AS grade_au_count,
       count(*) FILTER (WHERE g.official_grade_code = 'B') AS grade_b_count,
       count(*) FILTER (WHERE g.official_grade_code = 'C') AS grade_c_count,
       count(*) FILTER (WHERE g.official_grade_code = 'D') AS grade_d_count,
       count(*) FILTER (WHERE g.official_grade_code = 'F') AS grade_f_count,
       count(*) FILTER (WHERE g.official_grade_code = 'FX') AS grade_fx_count,
       count(*) FILTER (WHERE g.official_grade_code = 'I') AS grade_i_count,
       count(*) FILTER (WHERE g.official_grade_code = 'IP') AS grade_ip_count,
       count(*) FILTER (WHERE g.official_grade_code = 'N') AS grade_n_count,
       count(*) FILTER (WHERE g.official_grade_code = 'NC') AS grade_nc_count,
       count(*) FILTER (WHERE g.official_grade_code = 'NS') AS grade_ns_count,
       count(*) FILTER (WHERE g.official_grade_code = 'NTG') AS grade_ntg_count,
       count(*) FILTER (WHERE g.official_grade_code = 'P') AS grade_p_count,
       count(*) FILTER (WHERE g.official_grade_code = 'S') AS grade_s_count,
       count(*) FILTER (WHERE g.official_grade_code = 'W') AS grade_w_count,
       count(*) FILTER (WHERE g.official_grade_code = 'WF') AS grade_wf_count,
       count(*) FILTER (WHERE g.official_grade_code IS NULL
                         OR g.official_grade_code NOT IN ('A','AU','B','C','D','F','FX','I','IP','N','NC','NS','NTG','P','S','W','WF')) AS other_grade_count,
       min(g.import_batch_id::text)::uuid AS core_import_batch_id
FROM core.grade g
JOIN core.term t ON t.term_id = g.term_id
LEFT JOIN reporting.course_current_catalog_api c ON c.course_id = g.course_id
WHERE g.course_id IS NOT NULL
GROUP BY g.course_id, g.term_id, t.term_code, t.term_label,
         c.university_course_id, c.course_code, c.course_title, c.college_name, c.department_name;

CREATE TEMP TABLE tmp_enrollment_summary ON COMMIT DROP AS
SELECT o.course_id, o.term_id, t.term_code, t.term_label,
       c.university_course_id, c.course_code, c.course_title, c.college_name, c.department_name,
       count(*) AS offering_count,
       sum(o.enrollment_count)::numeric AS enrollment_count,
       min(o.enrollment_count) AS minimum_section_enrollment,
       max(o.enrollment_count) AS maximum_section_enrollment,
       min(o.import_batch_id::text)::uuid AS core_import_batch_id
FROM core.course_offering_section o
JOIN core.term t ON t.term_id = o.term_id
LEFT JOIN reporting.course_current_catalog_api c ON c.course_id = o.course_id
WHERE o.enrollment_count IS NOT NULL
GROUP BY o.course_id, o.term_id, t.term_code, t.term_label,
         c.university_course_id, c.course_code, c.course_title, c.college_name, c.department_name;

CREATE TEMP TABLE tmp_dfwi_summary ON COMMIT DROP AS
SELECT e.course_id, e.term_id, e.term_code, e.term_label,
       e.university_course_id, e.course_code, e.course_title, e.college_name, e.department_name,
       e.enrollment_count,
       coalesce(g.d, 0) AS d_count, coalesce(g.f, 0) AS f_count, coalesce(g.w, 0) AS w_count, coalesce(g.i, 0) AS i_count,
       coalesce(g.d, 0) + coalesce(g.f, 0) + coalesce(g.w, 0) + coalesce(g.i, 0) AS dfwi_count,
       round((coalesce(g.d, 0) + coalesce(g.f, 0) + coalesce(g.w, 0) + coalesce(g.i, 0)) * 100.0 / nullif(e.enrollment_count, 0), 2) AS dfwi_rate_pct
FROM tmp_enrollment_summary e
LEFT JOIN (
  SELECT course_id, term_id,
         count(*) FILTER (WHERE official_grade_code = 'D') AS d,
         count(*) FILTER (WHERE official_grade_code = 'F') AS f,
         count(*) FILTER (WHERE official_grade_code = 'W') AS w,
         count(*) FILTER (WHERE official_grade_code = 'I') AS i
  FROM core.grade WHERE course_id IS NOT NULL GROUP BY course_id, term_id
) g ON g.course_id = e.course_id AND g.term_id = e.term_id;
