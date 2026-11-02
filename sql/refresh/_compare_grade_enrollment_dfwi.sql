-- Compares the rebuilt summaries with the live tables, column by column.
\echo '### V1 REBUILT VS LIVE (rows in one but not the other; all should be 0)'
SELECT 'grade' AS summary,
  (SELECT count(*) FROM tmp_grade_summary) AS rebuilt_rows,
  (SELECT count(*) FROM reporting.course_grade_summary) AS live_rows,
  (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, grade_count, scored_count, average_final_score, grade_a_count, grade_au_count, grade_b_count, grade_c_count, grade_d_count, grade_f_count, grade_fx_count, grade_i_count, grade_ip_count, grade_n_count, grade_nc_count, grade_ns_count, grade_ntg_count, grade_p_count, grade_s_count, grade_w_count, grade_wf_count, other_grade_count, core_import_batch_id FROM tmp_grade_summary
     EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, grade_count, scored_count, average_final_score, grade_a_count, grade_au_count, grade_b_count, grade_c_count, grade_d_count, grade_f_count, grade_fx_count, grade_i_count, grade_ip_count, grade_n_count, grade_nc_count, grade_ns_count, grade_ntg_count, grade_p_count, grade_s_count, grade_w_count, grade_wf_count, other_grade_count, core_import_batch_id FROM reporting.course_grade_summary) x) AS only_in_rebuilt,
  (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, grade_count, scored_count, average_final_score, grade_a_count, grade_au_count, grade_b_count, grade_c_count, grade_d_count, grade_f_count, grade_fx_count, grade_i_count, grade_ip_count, grade_n_count, grade_nc_count, grade_ns_count, grade_ntg_count, grade_p_count, grade_s_count, grade_w_count, grade_wf_count, other_grade_count, core_import_batch_id FROM reporting.course_grade_summary
     EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, grade_count, scored_count, average_final_score, grade_a_count, grade_au_count, grade_b_count, grade_c_count, grade_d_count, grade_f_count, grade_fx_count, grade_i_count, grade_ip_count, grade_n_count, grade_nc_count, grade_ns_count, grade_ntg_count, grade_p_count, grade_s_count, grade_w_count, grade_wf_count, other_grade_count, core_import_batch_id FROM tmp_grade_summary) x) AS only_in_live
UNION ALL SELECT 'enrollment',
  (SELECT count(*) FROM tmp_enrollment_summary), (SELECT count(*) FROM reporting.course_enrollment_summary),
  (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, offering_count, enrollment_count, minimum_section_enrollment, maximum_section_enrollment, core_import_batch_id FROM tmp_enrollment_summary
     EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, offering_count, enrollment_count, minimum_section_enrollment, maximum_section_enrollment, core_import_batch_id FROM reporting.course_enrollment_summary) x),
  (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, offering_count, enrollment_count, minimum_section_enrollment, maximum_section_enrollment, core_import_batch_id FROM reporting.course_enrollment_summary
     EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, offering_count, enrollment_count, minimum_section_enrollment, maximum_section_enrollment, core_import_batch_id FROM tmp_enrollment_summary) x)
UNION ALL SELECT 'dfwi',
  (SELECT count(*) FROM tmp_dfwi_summary), (SELECT count(*) FROM reporting.course_dfwi_summary),
  (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, enrollment_count, d_count, f_count, w_count, i_count, dfwi_count, dfwi_rate_pct FROM tmp_dfwi_summary
     EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, enrollment_count, d_count, f_count, w_count, i_count, dfwi_count, dfwi_rate_pct FROM reporting.course_dfwi_summary) x),
  (SELECT count(*) FROM (SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, enrollment_count, d_count, f_count, w_count, i_count, dfwi_count, dfwi_rate_pct FROM reporting.course_dfwi_summary
     EXCEPT ALL SELECT course_id, term_id, term_code, term_label, university_course_id, course_code, course_title, college_name, department_name, enrollment_count, d_count, f_count, w_count, i_count, dfwi_count, dfwi_rate_pct FROM tmp_dfwi_summary) x);

\echo '### V2 FIRST DIFFERING COLUMN PER SUMMARY (diagnostic; empty when V1 is all 0)'
SELECT 'grade' AS summary, col, count(*) AS rows_differing FROM tmp_grade_summary n JOIN reporting.course_grade_summary l USING (course_id, term_id)
CROSS JOIN LATERAL (VALUES
  ('term_code', n.term_code IS DISTINCT FROM l.term_code), ('term_label', n.term_label IS DISTINCT FROM l.term_label),
  ('catalog columns', (n.university_course_id, n.course_code, n.course_title, n.college_name, n.department_name) IS DISTINCT FROM (l.university_course_id, l.course_code, l.course_title, l.college_name, l.department_name)),
  ('grade_count', n.grade_count IS DISTINCT FROM l.grade_count), ('scored_count', n.scored_count IS DISTINCT FROM l.scored_count),
  ('average_final_score', n.average_final_score IS DISTINCT FROM l.average_final_score), ('core_import_batch_id', n.core_import_batch_id IS DISTINCT FROM l.core_import_batch_id)
) v(col, differs) WHERE differs GROUP BY col
UNION ALL
SELECT 'enrollment', col, count(*) FROM tmp_enrollment_summary n JOIN reporting.course_enrollment_summary l USING (course_id, term_id)
CROSS JOIN LATERAL (VALUES
  ('catalog columns', (n.university_course_id, n.course_code, n.course_title, n.college_name, n.department_name) IS DISTINCT FROM (l.university_course_id, l.course_code, l.course_title, l.college_name, l.department_name)),
  ('counts', (n.offering_count, n.enrollment_count, n.minimum_section_enrollment, n.maximum_section_enrollment) IS DISTINCT FROM (l.offering_count, l.enrollment_count, l.minimum_section_enrollment, l.maximum_section_enrollment)),
  ('core_import_batch_id', n.core_import_batch_id IS DISTINCT FROM l.core_import_batch_id)
) v(col, differs) WHERE differs GROUP BY col
UNION ALL
SELECT 'dfwi', col, count(*) FROM tmp_dfwi_summary n JOIN reporting.course_dfwi_summary l USING (course_id, term_id)
CROSS JOIN LATERAL (VALUES
  ('counts', (n.d_count, n.f_count, n.w_count, n.i_count, n.dfwi_count) IS DISTINCT FROM (l.d_count, l.f_count, l.w_count, l.i_count, l.dfwi_count)),
  ('enrollment_count', n.enrollment_count IS DISTINCT FROM l.enrollment_count), ('dfwi_rate_pct', n.dfwi_rate_pct IS DISTINCT FROM l.dfwi_rate_pct)
) v(col, differs) WHERE differs GROUP BY col;

\echo '### V3 API IDS FROM REBUILT ROWS (should equal live API ids)'
SELECT 'grade' AS api, count(*) AS rows, count(*) FILTER (WHERE a.grade_summary_id = md5(n.course_id::text || ':' || n.term_id::text)::uuid) AS id_match
FROM tmp_grade_summary n JOIN reporting.course_grade_summary_api a USING (course_id, term_id)
UNION ALL SELECT 'enrollment', count(*), count(*) FILTER (WHERE a.enrollment_summary_id = md5(n.course_id::text || ':' || n.term_id::text)::uuid)
FROM tmp_enrollment_summary n JOIN reporting.course_enrollment_summary_api a USING (course_id, term_id)
UNION ALL SELECT 'dfwi', count(*), count(*) FILTER (WHERE a.dfwi_summary_id = md5(n.course_id::text || ':' || n.term_id::text)::uuid)
FROM tmp_dfwi_summary n JOIN reporting.course_dfwi_summary_api a USING (course_id, term_id);
