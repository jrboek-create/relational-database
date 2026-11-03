-- One-time setup: reporting table + API copy for faculty observation totals per course (same pattern as AI production).
-- No Emplids or comments are stored here; the CHECK enforces that courses with too few observations carry no ratings.
BEGIN;
CREATE TABLE reporting.course_observation_summary (
    course_key text NOT NULL,
    item_number integer NOT NULL,
    item_text text NOT NULL,
    course_id uuid,
    university_course_id text,
    course_code text,
    course_title text,
    college_name text,
    department_name text,
    raw_course text NOT NULL,
    catalog_match_status text NOT NULL,
    observation_count bigint NOT NULL,
    first_term_month text,
    last_term_month text,
    suppressed boolean NOT NULL,
    count_yes bigint,
    count_no bigint,
    count_exceeds bigint,
    count_meets bigint,
    count_below bigint,
    count_not_applicable bigint,
    count_coaching bigint,
    count_not_rated bigint,
    report_refresh_run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL,
    business_row_hash text NOT NULL,
    PRIMARY KEY (course_key, item_number),
    CHECK ((catalog_match_status = 'MATCHED' AND course_id IS NOT NULL) OR (catalog_match_status = 'UNMATCHED' AND course_id IS NULL)),
    CHECK (item_number BETWEEN 0 AND 15),
    -- privacy rule: a suppressed course has only the item-0 row, with no ratings
    CHECK (NOT suppressed OR (item_number = 0 AND count_yes IS NULL AND count_no IS NULL AND count_exceeds IS NULL AND count_meets IS NULL
                              AND count_below IS NULL AND count_not_applicable IS NULL AND count_coaching IS NULL AND count_not_rated IS NULL))
);
CREATE TABLE reporting.course_observation_summary_api (
    observation_summary_id uuid PRIMARY KEY,
    course_key text NOT NULL,
    item_number integer NOT NULL,
    item_text text NOT NULL,
    course_id uuid,
    university_course_id text,
    course_code text,
    course_title text,
    college_name text,
    department_name text,
    raw_course text NOT NULL,
    catalog_match_status text NOT NULL,
    observation_count bigint NOT NULL,
    first_term_month text,
    last_term_month text,
    suppressed boolean NOT NULL,
    count_yes bigint,
    count_no bigint,
    count_exceeds bigint,
    count_meets bigint,
    count_below bigint,
    count_not_applicable bigint,
    count_coaching bigint,
    count_not_rated bigint,
    report_refresh_run_id uuid NOT NULL,
    report_as_of_utc timestamptz NOT NULL,
    UNIQUE (course_key, item_number),
    CHECK ((catalog_match_status = 'MATCHED' AND course_id IS NOT NULL) OR (catalog_match_status = 'UNMATCHED' AND course_id IS NULL)),
    CHECK (item_number BETWEEN 0 AND 15),
    -- privacy rule: a suppressed course has only the item-0 row, with no ratings
    CHECK (NOT suppressed OR (item_number = 0 AND count_yes IS NULL AND count_no IS NULL AND count_exceeds IS NULL AND count_meets IS NULL
                              AND count_below IS NULL AND count_not_applicable IS NULL AND count_coaching IS NULL AND count_not_rated IS NULL))
);
CREATE INDEX ON reporting.course_observation_summary_api (course_id);
ALTER TABLE reporting.course_observation_summary OWNER TO directus_repository;
ALTER TABLE reporting.course_observation_summary_api OWNER TO directus_repository;
GRANT SELECT ON reporting.course_observation_summary_api TO directus_runtime;
COMMIT;
