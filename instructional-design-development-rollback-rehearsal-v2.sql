\set ON_ERROR_STOP on
\pset pager off
\timing on

BEGIN;

-- AIR Course Development Master Hub
-- Instructional design and development
-- Audit-enabled rollback rehearsal
--
-- Governed source:
--   staging.raw_master_idd_product_s02_idd_prod_schd_40a4d388
--
-- Accepted source population:
--   1,159 business rows after excluding the embedded header row
--
-- Internal grain:
--   source_hash + source_row_number
--
-- Catalog and institutional-term matches are intentionally nullable.
-- This preserves all governed source rows without inventing mappings.

DO $preflight$
BEGIN
    IF to_regclass('reporting.course_instructional_design_development_summary') IS NOT NULL THEN
        RAISE EXCEPTION
            'Preflight failed: reporting.course_instructional_design_development_summary already exists';
    END IF;

    IF to_regclass('reporting.course_instructional_design_development_summary_api') IS NOT NULL THEN
        RAISE EXCEPTION
            'Preflight failed: reporting.course_instructional_design_development_summary_api already exists';
    END IF;

    IF to_regclass('reporting.projection_refresh_run') IS NULL THEN
        RAISE EXCEPTION
            'Preflight failed: reporting.projection_refresh_run does not exist';
    END IF;
END
$preflight$;

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

CREATE TABLE reporting.course_instructional_design_development_summary (
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

INSERT INTO reporting.course_instructional_design_development_summary (
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

CREATE INDEX course_instructional_design_development_summary_course_id_idx
    ON reporting.course_instructional_design_development_summary (course_id)
    WHERE course_id IS NOT NULL;

CREATE INDEX course_instructional_design_development_summary_course_code_idx
    ON reporting.course_instructional_design_development_summary (course_code)
    WHERE course_code IS NOT NULL;

CREATE INDEX course_instructional_design_development_summary_term_id_idx
    ON reporting.course_instructional_design_development_summary (term_id)
    WHERE term_id IS NOT NULL;

CREATE INDEX course_instructional_design_development_summary_term_code_idx
    ON reporting.course_instructional_design_development_summary (term_code)
    WHERE term_code IS NOT NULL;

CREATE INDEX course_instructional_design_development_summary_idd_month_idx
    ON reporting.course_instructional_design_development_summary (idd_year_month);

CREATE INDEX course_instructional_design_development_summary_status_idx
    ON reporting.course_instructional_design_development_summary (project_status);

CREATE INDEX course_instructional_design_development_summary_lookup_idx
    ON reporting.course_instructional_design_development_summary
        (course_id, idd_year_month, project_status)
    WHERE course_id IS NOT NULL;

CREATE TABLE reporting.course_instructional_design_development_summary_api AS
SELECT
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
    source_hash,
    source_row_number,
    MD5(source_hash || ':' || source_row_number::text)::uuid
        AS instructional_design_development_summary_id
FROM reporting.course_instructional_design_development_summary;

ALTER TABLE reporting.course_instructional_design_development_summary_api
    ALTER COLUMN instructional_design_development_summary_id SET NOT NULL;

ALTER TABLE reporting.course_instructional_design_development_summary_api
    ADD CONSTRAINT course_instructional_design_development_summary_api_pkey
    PRIMARY KEY (instructional_design_development_summary_id);

ALTER TABLE reporting.course_instructional_design_development_summary_api
    ADD CONSTRAINT course_instructional_design_development_summary_api_business_key
    UNIQUE (source_hash, source_row_number);

CREATE INDEX course_instructional_design_development_summary_api_course_idx
    ON reporting.course_instructional_design_development_summary_api
        (course_id, idd_year_month, project_status)
    WHERE course_id IS NOT NULL;

CREATE INDEX course_instructional_design_development_summary_api_course_code_idx
    ON reporting.course_instructional_design_development_summary_api (course_code)
    WHERE course_code IS NOT NULL;

CREATE INDEX course_instructional_design_development_summary_api_term_code_idx
    ON reporting.course_instructional_design_development_summary_api (term_code)
    WHERE term_code IS NOT NULL;

CREATE INDEX course_instructional_design_development_summary_api_idd_month_idx
    ON reporting.course_instructional_design_development_summary_api (idd_year_month);

CREATE INDEX course_instructional_design_development_summary_api_status_idx
    ON reporting.course_instructional_design_development_summary_api (project_status);

DO $acceptance$
DECLARE
    a record;
BEGIN
    SELECT
        COUNT(*) AS candidate_rows,
        COUNT(DISTINCT (source_hash, source_row_number)) AS distinct_source_rows,
        COUNT(DISTINCT raw_course) AS distinct_raw_courses,
        COUNT(DISTINCT idd_year_month) AS distinct_idd_months,
        COUNT(*) FILTER (WHERE catalog_match_status = 'MATCHED') AS catalog_matched_rows,
        COUNT(*) FILTER (WHERE catalog_match_status = 'UNMATCHED') AS catalog_unmatched_rows,
        COUNT(*) FILTER (WHERE institutional_term_match_status = 'MATCHED') AS term_matched_rows,
        COUNT(*) FILTER (WHERE institutional_term_match_status = 'UNMATCHED') AS term_unmatched_rows,
        COUNT(*) FILTER (WHERE project_status = 'Completed') AS completed_rows,
        COUNT(*) FILTER (WHERE project_status = 'Removed') AS removed_rows,
        COUNT(*) FILTER (WHERE project_status = 'Moved to 2026-2027 Schedule') AS moved_rows,
        COUNT(*) FILTER (WHERE project_status = 'Canceled') AS canceled_rows,
        COUNT(*) FILTER (WHERE project_status = 'Placeholder') AS placeholder_rows,
        COUNT(*) FILTER (WHERE project_status = 'Not Started Yet') AS not_started_rows,
        COUNT(*) FILTER (WHERE project_status = 'In Progress') AS in_progress_rows,
        COUNT(*) FILTER (WHERE course_developer IS NOT NULL) AS rows_with_course_developer,
        COUNT(*) FILTER (WHERE instructional_designer IS NOT NULL) AS rows_with_instructional_designer,
        MIN(idd_year_month) AS earliest_idd_month,
        MAX(idd_year_month) AS latest_idd_month,
        MIN(source_row_number) AS minimum_source_row_number,
        MAX(source_row_number) AS maximum_source_row_number,
        COUNT(DISTINCT source_hash) AS distinct_source_hashes,
        COUNT(DISTINCT instructional_design_development_summary_id) AS distinct_api_ids
    INTO a
    FROM reporting.course_instructional_design_development_summary_api;

    IF a.candidate_rows <> 1159 THEN
        RAISE EXCEPTION 'Acceptance failed: candidate_rows %, expected 1159', a.candidate_rows;
    END IF;
    IF a.distinct_source_rows <> 1159 THEN
        RAISE EXCEPTION 'Acceptance failed: distinct_source_rows %, expected 1159', a.distinct_source_rows;
    END IF;
    IF a.distinct_raw_courses <> 735 THEN
        RAISE EXCEPTION 'Acceptance failed: distinct_raw_courses %, expected 735', a.distinct_raw_courses;
    END IF;
    IF a.distinct_idd_months <> 23 THEN
        RAISE EXCEPTION 'Acceptance failed: distinct_idd_months %, expected 23', a.distinct_idd_months;
    END IF;
    IF a.catalog_matched_rows <> 621 OR a.catalog_unmatched_rows <> 538 THEN
        RAISE EXCEPTION
            'Acceptance failed: catalog matched/unmatched %/%, expected 621/538',
            a.catalog_matched_rows, a.catalog_unmatched_rows;
    END IF;
    IF a.term_matched_rows <> 929 OR a.term_unmatched_rows <> 230 THEN
        RAISE EXCEPTION
            'Acceptance failed: term matched/unmatched %/%, expected 929/230',
            a.term_matched_rows, a.term_unmatched_rows;
    END IF;
    IF a.completed_rows <> 949
       OR a.removed_rows <> 84
       OR a.moved_rows <> 49
       OR a.canceled_rows <> 38
       OR a.placeholder_rows <> 34
       OR a.not_started_rows <> 4
       OR a.in_progress_rows <> 1 THEN
        RAISE EXCEPTION 'Acceptance failed: project-status census does not reconcile';
    END IF;
    IF a.rows_with_course_developer <> 695 THEN
        RAISE EXCEPTION
            'Acceptance failed: rows_with_course_developer %, expected 695',
            a.rows_with_course_developer;
    END IF;
    IF a.rows_with_instructional_designer <> 1006 THEN
        RAISE EXCEPTION
            'Acceptance failed: rows_with_instructional_designer %, expected 1006',
            a.rows_with_instructional_designer;
    END IF;
    IF a.earliest_idd_month <> '2024-10' OR a.latest_idd_month <> '2026-08' THEN
        RAISE EXCEPTION
            'Acceptance failed: IDD month range % to %, expected 2024-10 to 2026-08',
            a.earliest_idd_month, a.latest_idd_month;
    END IF;
    IF a.minimum_source_row_number <> 4489
       OR a.maximum_source_row_number <> 5647
       OR a.distinct_source_hashes <> 1 THEN
        RAISE EXCEPTION 'Acceptance failed: source-stability census does not reconcile';
    END IF;
    IF a.distinct_api_ids <> 1159 THEN
        RAISE EXCEPTION
            'Acceptance failed: distinct_api_ids %, expected 1159',
            a.distinct_api_ids;
    END IF;
END
$acceptance$;

WITH checksum AS (
    SELECT MD5(
        STRING_AGG(
            business_row_hash,
            ''
            ORDER BY source_hash, source_row_number
        )
    ) AS business_checksum
    FROM reporting.course_instructional_design_development_summary
),
inserted_audit AS (
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
        b.run_id,
        'course_instructional_design_development_summary',
        b.report_as_of_utc,
        clock_timestamp(),
        jsonb_build_object(
            'grain', 'source_hash + source_row_number',
            'source', 'staging.raw_master_idd_product_s02_idd_prod_schd_40a4d388',
            'embedded_header_rule', 'exclude Project Status = Project Status',
            'catalog_authority', 'reporting.course_current_catalog',
            'term_authority', 'reporting.course_enrollment_summary',
            'unmatched_record_rule', 'preserve with nullable catalog and term identities',
            'modified_timestamp_rule', 'Excel serial date using 1899-12-30 epoch'
        ),
        jsonb_build_object(
            'expected_rows', 1159,
            'expected_distinct_raw_courses', 735,
            'expected_idd_months', 23,
            'expected_catalog_matched_rows', 621,
            'expected_catalog_unmatched_rows', 538,
            'expected_term_matched_rows', 929,
            'expected_term_unmatched_rows', 230,
            'expected_completed_rows', 949,
            'expected_removed_rows', 84,
            'expected_moved_rows', 49,
            'expected_canceled_rows', 38,
            'expected_placeholder_rows', 34,
            'expected_not_started_rows', 4,
            'expected_in_progress_rows', 1,
            'expected_course_developer_rows', 695,
            'expected_instructional_designer_rows', 1006,
            'expected_earliest_idd_month', '2024-10',
            'expected_latest_idd_month', '2026-08'
        ),
        1159,
        1159,
        0,
        0,
        0,
        c.business_checksum,
        'COMPLETED',
        'Instructional design and development rollback rehearsal completed and reconciled.',
        NULL
    FROM idd_build_context AS b
    CROSS JOIN checksum AS c
    RETURNING
        run_id,
        projection_name,
        source_row_count,
        rows_inserted,
        business_checksum,
        status,
        notes
)
SELECT *
FROM inserted_audit;

SELECT
    COUNT(*) AS summary_rows,
    COUNT(DISTINCT (source_hash, source_row_number)) AS distinct_business_keys,
    COUNT(*) FILTER (WHERE course_id IS NOT NULL) AS catalog_matched_rows,
    COUNT(*) FILTER (WHERE course_id IS NULL) AS catalog_unmatched_rows,
    COUNT(*) FILTER (WHERE term_id IS NOT NULL) AS term_matched_rows,
    COUNT(*) FILTER (WHERE term_id IS NULL) AS term_unmatched_rows,
    COUNT(DISTINCT idd_year_month) AS distinct_idd_months,
    MIN(idd_year_month) AS earliest_idd_month,
    MAX(idd_year_month) AS latest_idd_month
FROM reporting.course_instructional_design_development_summary;

SELECT
    COUNT(*) AS api_rows,
    COUNT(DISTINCT instructional_design_development_summary_id) AS distinct_api_ids,
    COUNT(DISTINCT (source_hash, source_row_number)) AS distinct_api_business_keys
FROM reporting.course_instructional_design_development_summary_api;

SELECT
    project_status,
    COUNT(*) AS rows
FROM reporting.course_instructional_design_development_summary
GROUP BY project_status
ORDER BY rows DESC, project_status;

ROLLBACK;
