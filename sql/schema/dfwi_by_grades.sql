-- One-time (3 Nov 2026): DFWI follows Tableau. Rate = (D + F + W + I) / grades * 100, where grades = the 12 codes Tableau
-- reports (A, B, C, D, F, W, I, AU, NS, NTG, P, WF), pooled across a course's sections in a term. Enrollment stays as a
-- reference column and may be empty (course-terms with grades but no enrollment are now included).
-- Run once, then `upload refresh` to rebuild DFWI with the new rule, then restart Directus so it sees the new column.
BEGIN;
ALTER TABLE reporting.course_dfwi_summary ADD COLUMN IF NOT EXISTS grade_count bigint;
ALTER TABLE reporting.course_dfwi_summary_api ADD COLUMN IF NOT EXISTS grade_count bigint;
ALTER TABLE reporting.course_dfwi_summary ALTER COLUMN enrollment_count DROP NOT NULL;
ALTER TABLE reporting.course_dfwi_summary_api ALTER COLUMN enrollment_count DROP NOT NULL;
ALTER TABLE reporting.course_dfwi_summary DROP CONSTRAINT IF EXISTS ck_course_dfwi_summary_counts;
ALTER TABLE reporting.course_dfwi_summary ADD CONSTRAINT ck_course_dfwi_summary_counts CHECK (
    grade_count > 0 AND d_count >= 0 AND f_count >= 0 AND w_count >= 0 AND i_count >= 0
    AND dfwi_count = d_count + f_count + w_count + i_count
    AND dfwi_count <= grade_count
    AND (enrollment_count IS NULL OR enrollment_count >= 0)
    AND dfwi_rate_pct >= 0 AND dfwi_rate_pct <= 100) NOT VALID;   -- existing rows are checked when the refresh rebuilds them
COMMIT;
