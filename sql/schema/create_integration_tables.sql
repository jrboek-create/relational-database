-- One-time setup: reporting table + API copy for course integrations (same pattern as AI production).
BEGIN;
CREATE TABLE reporting.course_integration_summary (
    source_hash text NOT NULL,
    source_row_number bigint NOT NULL,
    integration_name text NOT NULL,
    integration_order integer NOT NULL,
    course_id uuid,
    university_course_id text,
    course_code text,
    course_title text,
    college_name text,
    department_name text,
    raw_course text NOT NULL,
    catalog_match_status text NOT NULL,
    date_meaning text NOT NULL,
    integration_month text NOT NULL,
    report_refresh_run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL,
    business_row_hash text NOT NULL,
    PRIMARY KEY (source_hash, source_row_number, integration_name),
    CHECK ((catalog_match_status = 'MATCHED' AND course_id IS NOT NULL) OR (catalog_match_status = 'UNMATCHED' AND course_id IS NULL)),
    CHECK (date_meaning IN ('last', 'start', 'unknown')),
    CHECK (integration_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$')
);
CREATE TABLE reporting.course_integration_summary_api (
    integration_summary_id uuid PRIMARY KEY,
    source_hash text NOT NULL,
    source_row_number bigint NOT NULL,
    integration_name text NOT NULL,
    integration_order integer NOT NULL,
    course_id uuid,
    university_course_id text,
    course_code text,
    course_title text,
    college_name text,
    department_name text,
    raw_course text NOT NULL,
    catalog_match_status text NOT NULL,
    date_meaning text NOT NULL,
    integration_month text NOT NULL,
    report_refresh_run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL,
    UNIQUE (source_hash, source_row_number, integration_name)
);
CREATE INDEX ON reporting.course_integration_summary_api (course_id);
ALTER TABLE reporting.course_integration_summary OWNER TO directus_repository;
ALTER TABLE reporting.course_integration_summary_api OWNER TO directus_repository;
GRANT SELECT ON reporting.course_integration_summary_api TO directus_runtime;
COMMIT;
