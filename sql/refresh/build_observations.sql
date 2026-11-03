-- Builds tmp_course_observation_summary (a temporary table): faculty observation totals per course, all terms combined,
-- from the "Faculty Obs Master" sheet. One row per course and item: item 0 = overall rating, items 1-15 = the standards.
-- Privacy (decided 3 Nov 2026): no Emplids and no comments; courses with fewer than 3 observations get only an item-0 row
-- with the observation count (suppressed = true) and no ratings, so no individual instructor's evaluation can be read.
-- Columns are found through the staging column map by header name. Courses link to the current catalog by course code.

CREATE TEMP TABLE observation_refresh_context ON COMMIT DROP AS
SELECT gen_random_uuid() AS run_id, CURRENT_TIMESTAMP AS report_as_of_utc, 3 AS minimum_observations;

CREATE TEMP TABLE tmp_course_observation_summary ON COMMIT DROP AS
WITH colmap AS (
    SELECT BTRIM(m.source_header) AS header, m.staged_column
    FROM staging._phase2_column_map m
    JOIN staging._phase2_components c USING (component_id)
    WHERE c.staging_table = 'raw_faculty_obs_master_s02_faculty_obs_master_49ca0349'
),
k AS (
    SELECT (SELECT staged_column FROM colmap WHERE header = 'Observation Id' LIMIT 1) AS obs_id,
           (SELECT staged_column FROM colmap WHERE header = 'Course' LIMIT 1) AS course,
           (SELECT staged_column FROM colmap WHERE header = 'Term' LIMIT 1) AS term,
           (SELECT staged_column FROM colmap WHERE header = 'Overall Rating' LIMIT 1) AS overall
),
obs AS (
    SELECT to_jsonb(r) AS j,
           NULLIF(BTRIM(to_jsonb(r) ->> k.obs_id), '') AS obs_id,
           NULLIF(BTRIM(SPLIT_PART(to_jsonb(r) ->> k.course, ' - ', 1)), '') AS raw_course,
           SUBSTRING(to_jsonb(r) ->> k.term FROM '[0-9]{4}-[0-9]{2}') AS term_month,
           NULLIF(BTRIM(to_jsonb(r) ->> k.overall), '') AS overall
    FROM staging.raw_faculty_obs_master_s02_faculty_obs_master_49ca0349 r CROSS JOIN k
    WHERE r.source_row_number IS NOT NULL
),
valid AS (
    SELECT *, UPPER(REPLACE(raw_course, ' ', '')) AS course_key
    FROM obs WHERE obs_id IS NOT NULL AND LOWER(obs_id) <> 'observation id' AND raw_course IS NOT NULL
),
courses AS (
    SELECT v.course_key, MIN(v.raw_course) AS raw_course, COUNT(DISTINCT v.obs_id) AS observation_count,
           MIN(v.term_month) AS first_term_month, MAX(v.term_month) AS last_term_month,
           COUNT(DISTINCT v.obs_id) < MIN(ctx.minimum_observations) AS suppressed
    FROM valid v CROSS JOIN observation_refresh_context ctx
    GROUP BY v.course_key
),
standards AS (   -- items 1-15, only for courses that are not suppressed
    SELECT v.course_key, i.n AS item_number,
           COALESCE(MIN(NULLIF(BTRIM(v.j ->> qc.staged_column), '')), 'Standard ' || i.n) AS item_text,
           COUNT(*) FILTER (WHERE BTRIM(v.j ->> rc.staged_column) = 'Y') AS count_yes,
           COUNT(*) FILTER (WHERE BTRIM(v.j ->> rc.staged_column) = 'N') AS count_no,
           COUNT(*) FILTER (WHERE BTRIM(v.j ->> rc.staged_column) = 'E') AS count_exceeds,
           COUNT(*) FILTER (WHERE BTRIM(v.j ->> rc.staged_column) = 'M') AS count_meets,
           COUNT(*) FILTER (WHERE BTRIM(v.j ->> rc.staged_column) = 'B') AS count_below,
           COUNT(*) FILTER (WHERE BTRIM(v.j ->> rc.staged_column) = 'NA') AS count_not_applicable,
           0::bigint AS count_coaching,
           COUNT(*) FILTER (WHERE NULLIF(BTRIM(v.j ->> rc.staged_column), '') IS NULL
                              OR BTRIM(v.j ->> rc.staged_column) NOT IN ('Y', 'N', 'E', 'M', 'B', 'NA')) AS count_not_rated
    FROM valid v
    JOIN courses c ON c.course_key = v.course_key AND NOT c.suppressed
    CROSS JOIN generate_series(1, 15) AS i(n)
    JOIN colmap rc ON rc.header = 'Response ' || i.n
    LEFT JOIN colmap qc ON qc.header = 'Question Txt' || i.n
    GROUP BY v.course_key, i.n
),
overall AS (     -- item 0; counts only when not suppressed
    SELECT c.course_key, 0 AS item_number, 'Overall rating'::text AS item_text,
           NULL::bigint AS count_yes, NULL::bigint AS count_no,
           CASE WHEN NOT c.suppressed THEN COUNT(*) FILTER (WHERE v.overall = 'Exceeds Expectations') END AS count_exceeds,
           CASE WHEN NOT c.suppressed THEN COUNT(*) FILTER (WHERE v.overall = 'Meets Expectations') END AS count_meets,
           CASE WHEN NOT c.suppressed THEN COUNT(*) FILTER (WHERE v.overall = 'Below Expectations') END AS count_below,
           NULL::bigint AS count_not_applicable,
           CASE WHEN NOT c.suppressed THEN COUNT(*) FILTER (WHERE v.overall ILIKE 'Recommend instructor engage in coaching%') END AS count_coaching,
           CASE WHEN NOT c.suppressed THEN COUNT(*) FILTER (WHERE v.overall IS NULL OR (v.overall NOT IN ('Exceeds Expectations', 'Meets Expectations', 'Below Expectations')
                                                                 AND v.overall NOT ILIKE 'Recommend instructor engage in coaching%')) END AS count_not_rated
    FROM courses c JOIN valid v ON v.course_key = c.course_key
    GROUP BY c.course_key, c.suppressed
),
items AS (SELECT * FROM overall UNION ALL SELECT * FROM standards)
SELECT c.course_key, i.item_number, i.item_text,
       cat.course_id, cat.university_course_id, cat.course_code, cat.course_title, cat.college_name, cat.department_name,
       c.raw_course,
       CASE WHEN cat.course_id IS NULL THEN 'UNMATCHED' ELSE 'MATCHED' END AS catalog_match_status,
       c.observation_count, c.first_term_month, c.last_term_month, c.suppressed,
       i.count_yes, i.count_no, i.count_exceeds, i.count_meets, i.count_below, i.count_not_applicable, i.count_coaching, i.count_not_rated,
       ctx.run_id AS report_refresh_run_id,
       ctx.report_as_of_utc,
       md5(concat_ws('|', c.course_key, i.item_number::text, i.item_text, cat.course_id::text, c.observation_count::text, c.first_term_month,
                     c.last_term_month, c.suppressed::text, i.count_yes::text, i.count_no::text, i.count_exceeds::text, i.count_meets::text,
                     i.count_below::text, i.count_not_applicable::text, i.count_coaching::text, i.count_not_rated::text)) AS business_row_hash
FROM items i
JOIN courses c ON c.course_key = i.course_key
LEFT JOIN reporting.course_current_catalog_api cat ON UPPER(REPLACE(cat.course_code, ' ', '')) = c.course_key
CROSS JOIN observation_refresh_context ctx;
