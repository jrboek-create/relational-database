-- One-time setup (NOT RUN YET): reporting table + API copy for AI production, following the existing pattern
-- (owner directus_repository; directus_runtime may only SELECT the _api copy). Directus registration is a separate step.
BEGIN;
CREATE TABLE reporting.course_ai_production_summary (
    source_hash text NOT NULL,
    source_row_number bigint NOT NULL,
    course_id uuid,
    university_course_id text,
    course_code text,
    course_title text,
    college_name text,
    department_name text,
    raw_course text NOT NULL,
    catalog_match_status text NOT NULL,
    implementation_month text,
    implementation_label text,
    project_name text,
    ai_type text,
    project_status text,
    description text,
    template_link text,
    source_college text,
    ai_section_count bigint NOT NULL,
    report_refresh_run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL,
    business_row_hash text NOT NULL,
    PRIMARY KEY (source_hash, source_row_number),
    CHECK ((catalog_match_status = 'MATCHED' AND course_id IS NOT NULL) OR (catalog_match_status = 'UNMATCHED' AND course_id IS NULL)),
    CHECK (implementation_month IS NULL OR implementation_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$')
);
CREATE TABLE reporting.course_ai_production_summary_api (
    ai_production_summary_id uuid PRIMARY KEY,
    source_hash text NOT NULL,
    source_row_number bigint NOT NULL,
    course_id uuid,
    university_course_id text,
    course_code text,
    course_title text,
    college_name text,
    department_name text,
    raw_course text NOT NULL,
    catalog_match_status text NOT NULL,
    implementation_month text,
    implementation_label text,
    project_name text,
    ai_type text,
    project_status text,
    description text,
    template_link text,
    source_college text,
    ai_section_count bigint NOT NULL,
    report_refresh_run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL,
    UNIQUE (source_hash, source_row_number)
);
CREATE INDEX ON reporting.course_ai_production_summary_api (course_id);
ALTER TABLE reporting.course_ai_production_summary OWNER TO directus_repository;
ALTER TABLE reporting.course_ai_production_summary_api OWNER TO directus_repository;
GRANT SELECT ON reporting.course_ai_production_summary_api TO directus_runtime;
COMMIT;
