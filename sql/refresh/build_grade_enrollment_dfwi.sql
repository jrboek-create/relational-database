-- Builds the Grades, Enrollment and DFWI summaries from the core tables into
-- temporary tables (tmp_grade_summary, tmp_enrollment_summary, tmp_dfwi_summary).
-- Rules reconstructed and verified on 2 Nov 2026 against the tables built 20 Oct 2026:
--   Grades:     core.grade per course + term, linked courses only (course_id not null).
--   Enrollment: core.course_offering_section per course + term, sections with an enrollment count only.
--   DFWI:       (changed 3 Nov 2026 to follow Tableau) one row per course + term with grades; D + F + W + I (WF excluded)
--               over grades in Tableau's 12 codes (A B C D F W I AU NS NTG P WF), pooled across sections, rounded to 2
--               decimals. Enrollment is attached for reference only. (Before: over enrollment, one row per enrollment row.)
--               COIN courses are never part of DFWI (as in Tableau, whose DFWI data source filters them out; confirmed 3 Nov 2026).
--               Their grades and enrollment are still reported.
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
SELECT x.course_id, x.term_id, x.term_code, x.term_label,
       x.university_course_id, x.course_code, x.course_title, x.college_name, x.department_name,
       e.enrollment_count,
       x.tableau_grades AS grade_count,
       x.d_count, x.f_count, x.w_count, x.i_count,
       x.d_count + x.f_count + x.w_count + x.i_count AS dfwi_count,
       round((x.d_count + x.f_count + x.w_count + x.i_count) * 100.0 / x.tableau_grades, 2) AS dfwi_rate_pct
FROM (
  SELECT g.*,
         g.grade_d_count AS d_count, g.grade_f_count AS f_count, g.grade_w_count AS w_count, g.grade_i_count AS i_count,
         g.grade_a_count + g.grade_b_count + g.grade_c_count + g.grade_d_count + g.grade_f_count + g.grade_w_count
           + g.grade_i_count + g.grade_au_count + g.grade_ns_count + g.grade_ntg_count + g.grade_p_count + g.grade_wf_count AS tableau_grades
  FROM tmp_grade_summary g
) x
LEFT JOIN tmp_enrollment_summary e ON e.course_id = x.course_id AND e.term_id = x.term_id
WHERE x.tableau_grades > 0
  AND coalesce(upper(x.course_code), '') NOT LIKE 'COIN %';
