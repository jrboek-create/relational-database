-- One-time setup: reporting table + API copy for redeveloped-course instructor feedback (same pattern as AI production).
-- Instructor name and email are deliberately not stored here.
BEGIN;
CREATE TABLE reporting.course_redeveloped_summary (
    source_hash text NOT NULL,
    source_row_number bigint NOT NULL,
    sis_source_id text NOT NULL,
    course_id uuid,
    university_course_id text,
    course_code text,
    course_title text,
    college_name text,
    department_name text,
    raw_course text NOT NULL,
    catalog_match_status text NOT NULL,
    term_id uuid,
    term_code text NOT NULL,
    term_label text,
    section_identifier text NOT NULL,
    responded boolean NOT NULL,
    response_date date,
    helpfulness_rating text,
    significant_changes text,
    changes_detail text,
    would_have_liked_to_know text,
    report_refresh_run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL,
    business_row_hash text NOT NULL,
    PRIMARY KEY (source_hash, source_row_number),
    CHECK ((catalog_match_status = 'MATCHED' AND course_id IS NOT NULL) OR (catalog_match_status = 'UNMATCHED' AND course_id IS NULL))
);
CREATE TABLE reporting.course_redeveloped_summary_api (
    redeveloped_summary_id uuid PRIMARY KEY,
    source_hash text NOT NULL,
    source_row_number bigint NOT NULL,
    sis_source_id text NOT NULL,
    course_id uuid,
    university_course_id text,
    course_code text,
    course_title text,
    college_name text,
    department_name text,
    raw_course text NOT NULL,
    catalog_match_status text NOT NULL,
    term_id uuid,
    term_code text NOT NULL,
    term_label text,
    section_identifier text NOT NULL,
    responded boolean NOT NULL,
    response_date date,
    helpfulness_rating text,
    significant_changes text,
    changes_detail text,
    would_have_liked_to_know text,
    report_refresh_run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL,
    UNIQUE (source_hash, source_row_number)
);
CREATE INDEX ON reporting.course_redeveloped_summary_api (course_id);
ALTER TABLE reporting.course_redeveloped_summary OWNER TO directus_repository;
ALTER TABLE reporting.course_redeveloped_summary_api OWNER TO directus_repository;
GRANT SELECT ON reporting.course_redeveloped_summary_api TO directus_runtime;
COMMIT;
