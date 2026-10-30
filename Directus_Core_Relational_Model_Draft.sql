BEGIN; 

  

CREATE EXTENSION IF NOT EXISTS pgcrypto; 

CREATE SCHEMA IF NOT EXISTS core; 

  

COMMENT ON SCHEMA core IS 

'Normalized logical core for the Directus Relational Repository. Draft pending final 811-row source-to-target reconciliation.'; 

  

-- ----------------------------------------------------------------------------- 

-- Reference and master entities 

-- ----------------------------------------------------------------------------- 

CREATE TABLE IF NOT EXISTS core.source_system ( 

    source_system_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    system_code text NOT NULL, 

    system_name text NOT NULL, 

    source_context text, 

    description text, 

    created_at timestamptz NOT NULL DEFAULT now() 

); 

COMMENT ON COLUMN core.source_system.system_code IS 

'Controlled source-system code. Add a UNIQUE constraint only after final source mapping confirms the controlled code set.'; 

  

CREATE TABLE IF NOT EXISTS core.import_batch ( 

    import_batch_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    source_system_id uuid NOT NULL REFERENCES core.source_system(source_system_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    batch_identifier text NOT NULL, 

    loaded_at timestamptz, 

    source_fingerprint text, 

    authoritative_indicator boolean NOT NULL DEFAULT false, 

    batch_status text NOT NULL DEFAULT 'REGISTERED', 

    notes text, 

    created_at timestamptz NOT NULL DEFAULT now() 

); 

COMMENT ON COLUMN core.import_batch.batch_identifier IS 

'Controlled ingestion identifier retained as text. Natural-key uniqueness remains pending final evidence.'; 

  

CREATE TABLE IF NOT EXISTS core.organization ( 

    organization_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    organization_code text, 

    organization_name text NOT NULL, 

    organization_type text, 

    parent_organization_id uuid REFERENCES core.organization(organization_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    effective_from date, 

    effective_to date, 

    is_current boolean, 

    created_at timestamptz NOT NULL DEFAULT now() 

); 

  

CREATE TABLE IF NOT EXISTS core.term ( 

    term_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    term_code text NOT NULL, 

    term_label text, 

    start_date date, 

    end_date date, 

    reporting_period_text text, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    created_at timestamptz NOT NULL DEFAULT now(), 

    CONSTRAINT ck_term_date_order CHECK (end_date IS NULL OR start_date IS NULL OR end_date >= start_date) 

); 

COMMENT ON COLUMN core.term.reporting_period_text IS 

'Preserved source-period text. Do not normalize without an approved transformation rule.'; 

  

CREATE TABLE IF NOT EXISTS core.lookup_reference_value ( 

    lookup_value_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    reference_domain text NOT NULL, 

    value_code text NOT NULL, 

    value_label text NOT NULL, 

    description text, 

    sort_order integer, 

    active_indicator boolean, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    created_at timestamptz NOT NULL DEFAULT now() 

); 

COMMENT ON TABLE core.lookup_reference_value IS 

'Controlled values are logically scoped by reference_domain. A domain+code UNIQUE constraint is intentionally deferred.'; 

  

CREATE TABLE IF NOT EXISTS core.course ( 

    course_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    course_code text, 

    course_title text, 

    academic_level_code text, 

    organization_id uuid REFERENCES core.organization(organization_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    effective_from date, 

    effective_to date, 

    is_current boolean, 

    created_at timestamptz NOT NULL DEFAULT now(), 

    CONSTRAINT ck_course_effective_order CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from) 

); 

COMMENT ON COLUMN core.course.course_code IS 

'Preserved as text. It is not assumed globally unique.'; 

  

CREATE TABLE IF NOT EXISTS core.person_instructor ( 

    person_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    person_source_identifier text, 

    display_name text, 

    email_address text, 

    person_type_value_id uuid REFERENCES core.lookup_reference_value(lookup_value_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    organization_id uuid REFERENCES core.organization(organization_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    effective_from date, 

    effective_to date, 

    is_current boolean, 

    created_at timestamptz NOT NULL DEFAULT now(), 

    CONSTRAINT ck_person_effective_order CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from) 

); 

COMMENT ON TABLE core.person_instructor IS 

'Contains sensitivity-controlled identity fields. Names and email addresses are not natural keys.'; 

  

CREATE TABLE IF NOT EXISTS core.course_offering_section ( 

    course_offering_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    course_id uuid NOT NULL REFERENCES core.course(course_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    term_id uuid REFERENCES core.term(term_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    section_identifier text, 

    source_section_identifier text, 

    modality_value_id uuid REFERENCES core.lookup_reference_value(lookup_value_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    enrollment_count integer, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    effective_from date, 

    effective_to date, 

    is_current boolean, 

    created_at timestamptz NOT NULL DEFAULT now(), 

    CONSTRAINT ck_offering_enrollment_nonnegative CHECK (enrollment_count IS NULL OR enrollment_count >= 0), 

    CONSTRAINT ck_offering_effective_order CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from) 

); 

  

-- ----------------------------------------------------------------------------- 

-- Supporting junction 

-- ----------------------------------------------------------------------------- 

CREATE TABLE IF NOT EXISTS core.instructor_assignment ( 

    instructor_assignment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    course_offering_id uuid NOT NULL REFERENCES core.course_offering_section(course_offering_id) ON UPDATE RESTRICT ON DELETE CASCADE, 

    person_id uuid NOT NULL REFERENCES core.person_instructor(person_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    assignment_role_value_id uuid REFERENCES core.lookup_reference_value(lookup_value_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    assignment_start date, 

    assignment_end date, 

    assignment_source_identifier text, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    created_at timestamptz NOT NULL DEFAULT now(), 

    CONSTRAINT ck_assignment_date_order CHECK (assignment_end IS NULL OR assignment_start IS NULL OR assignment_end >= assignment_start) 

); 

COMMENT ON TABLE core.instructor_assignment IS 

'Supporting junction; intentionally permits multiple instructors per offering and multiple offerings per instructor.'; 

  

-- ----------------------------------------------------------------------------- 

-- Transaction and activity entities 

-- Exception-affected business foreign keys are nullable by design. 

-- ----------------------------------------------------------------------------- 

CREATE TABLE IF NOT EXISTS core.faculty_observation ( 

    faculty_observation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    observation_source_identifier text, 

    observation_date date, 

    observer_person_id uuid REFERENCES core.person_instructor(person_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    instructor_person_id uuid REFERENCES core.person_instructor(person_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    course_id uuid REFERENCES core.course(course_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    course_offering_id uuid REFERENCES core.course_offering_section(course_offering_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    term_id uuid REFERENCES core.term(term_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    modality_value_id uuid REFERENCES core.lookup_reference_value(lookup_value_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    overall_rating text, 

    workflow_status text, 

    structured_responses jsonb, 

    comments_payload jsonb, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    created_at timestamptz NOT NULL DEFAULT now() 

); 

COMMENT ON TABLE core.faculty_observation IS 

'Observation records survive unresolved course, offering, observer, or instructor identifiers. comments_payload requires free-text controls.'; 

  

CREATE TABLE IF NOT EXISTS core.feedback_evaluation ( 

    feedback_evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    response_source_identifier text, 

    course_id uuid REFERENCES core.course(course_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    course_offering_id uuid REFERENCES core.course_offering_section(course_offering_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    term_id uuid REFERENCES core.term(term_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    instructor_person_id uuid REFERENCES core.person_instructor(person_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    organization_id uuid REFERENCES core.organization(organization_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    submitted_at timestamptz, 

    response_rate numeric, 

    response_payload jsonb, 

    demographic_payload jsonb, 

    submit_device text, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    created_at timestamptz NOT NULL DEFAULT now(), 

    CONSTRAINT ck_feedback_response_rate CHECK (response_rate IS NULL OR response_rate >= 0) 

); 

COMMENT ON TABLE core.feedback_evaluation IS 

'Instructor and offering references remain optional for current/historical source limitations. Payload fields require sensitivity review.'; 

  

CREATE TABLE IF NOT EXISTS core.grade ( 

    grade_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    grade_source_identifier text, 

    learner_source_identifier text, 

    course_id uuid REFERENCES core.course(course_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    course_offering_id uuid REFERENCES core.course_offering_section(course_offering_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    term_id uuid REFERENCES core.term(term_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    course_section_text text, 

    final_score numeric, 

    official_grade_code text, 

    start_period_text text, 

    enrollment_status text, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    created_at timestamptz NOT NULL DEFAULT now() 

); 

COMMENT ON TABLE core.grade IS 

'Preserves Final Grades source grain. course_offering_id is optional; learner_source_identifier and grade outcomes are sensitivity-controlled.'; 

COMMENT ON COLUMN core.grade.start_period_text IS 

'Preserved source-period text pending an approved transformation.'; 

  

CREATE TABLE IF NOT EXISTS core.production_activity ( 

    production_activity_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    activity_source_identifier text, 

    course_id uuid REFERENCES core.course(course_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    term_id uuid REFERENCES core.term(term_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    organization_id uuid REFERENCES core.organization(organization_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    assigned_person_id uuid REFERENCES core.person_instructor(person_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    activity_type_value_id uuid REFERENCES core.lookup_reference_value(lookup_value_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    status_value_id uuid REFERENCES core.lookup_reference_value(lookup_value_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    activity_name text, 

    start_date date, 

    target_date date, 

    completion_date date, 

    description text, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    created_at timestamptz NOT NULL DEFAULT now() 

); 

COMMENT ON TABLE core.production_activity IS 

'Consolidates source-supported IDD and AI production activity grains. Description is free text and the isolated AI exception remains external to forced matching.'; 

  

CREATE TABLE IF NOT EXISTS core.course_integration ( 

    course_integration_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    integration_source_identifier text, 

    course_id uuid REFERENCES core.course(course_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    course_offering_id uuid REFERENCES core.course_offering_section(course_offering_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    term_id uuid REFERENCES core.term(term_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    organization_id uuid REFERENCES core.organization(organization_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    integration_reference text, 

    integration_title text, 

    status_value_id uuid REFERENCES core.lookup_reference_value(lookup_value_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    request_date date, 

    completion_date date, 

    requestor_person_id uuid REFERENCES core.person_instructor(person_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    assigned_person_id uuid REFERENCES core.person_instructor(person_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    notes text, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    created_at timestamptz NOT NULL DEFAULT now() 

); 

COMMENT ON TABLE core.course_integration IS 

'Integration relationships remain optional where source coverage does not support resolution. Notes require free-text controls.'; 

  

CREATE TABLE IF NOT EXISTS core.redeveloped_course_response ( 

    redeveloped_response_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), 

    response_source_identifier text, 

    course_id uuid REFERENCES core.course(course_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    course_offering_id uuid REFERENCES core.course_offering_section(course_offering_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    term_id uuid REFERENCES core.term(term_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    person_id uuid REFERENCES core.person_instructor(person_id) ON UPDATE RESTRICT ON DELETE SET NULL, 

    source_year_text text, 

    course_link text, 

    response_text text, 

    comments text, 

    import_batch_id uuid NOT NULL REFERENCES core.import_batch(import_batch_id) ON UPDATE RESTRICT ON DELETE RESTRICT, 

    source_identifier text, 

    source_record_locator text NOT NULL, 

    source_version_label text, 

    created_at timestamptz NOT NULL DEFAULT now() 

); 

COMMENT ON TABLE core.redeveloped_course_response IS 

'Preserves the source-supported survey/response grain and SIS population/scope difference. Response and comments require free-text controls.'; 

  

-- ----------------------------------------------------------------------------- 

-- Conservative non-unique indexes supporting joins and lineage. 

-- Natural-key unique indexes remain pending final 811-row mapping validation. 

-- ----------------------------------------------------------------------------- 

CREATE INDEX IF NOT EXISTS ix_import_batch_source_system ON core.import_batch(source_system_id); 

CREATE INDEX IF NOT EXISTS ix_organization_import_batch ON core.organization(import_batch_id); 

CREATE INDEX IF NOT EXISTS ix_term_import_batch ON core.term(import_batch_id); 

CREATE INDEX IF NOT EXISTS ix_lookup_domain_code ON core.lookup_reference_value(reference_domain, value_code); 

CREATE INDEX IF NOT EXISTS ix_course_code ON core.course(course_code); 

CREATE INDEX IF NOT EXISTS ix_course_import_batch ON core.course(import_batch_id); 

CREATE INDEX IF NOT EXISTS ix_person_source_identifier ON core.person_instructor(person_source_identifier); 

CREATE INDEX IF NOT EXISTS ix_person_import_batch ON core.person_instructor(import_batch_id); 

CREATE INDEX IF NOT EXISTS ix_offering_course ON core.course_offering_section(course_id); 

CREATE INDEX IF NOT EXISTS ix_offering_term ON core.course_offering_section(term_id); 

CREATE INDEX IF NOT EXISTS ix_offering_section_identifier ON core.course_offering_section(section_identifier); 

CREATE INDEX IF NOT EXISTS ix_assignment_offering ON core.instructor_assignment(course_offering_id); 

CREATE INDEX IF NOT EXISTS ix_assignment_person ON core.instructor_assignment(person_id); 

CREATE INDEX IF NOT EXISTS ix_observation_course ON core.faculty_observation(course_id); 

CREATE INDEX IF NOT EXISTS ix_observation_offering ON core.faculty_observation(course_offering_id); 

CREATE INDEX IF NOT EXISTS ix_feedback_course ON core.feedback_evaluation(course_id); 

CREATE INDEX IF NOT EXISTS ix_feedback_offering ON core.feedback_evaluation(course_offering_id); 

CREATE INDEX IF NOT EXISTS ix_grade_course ON core.grade(course_id); 

CREATE INDEX IF NOT EXISTS ix_grade_offering ON core.grade(course_offering_id); 

CREATE INDEX IF NOT EXISTS ix_production_course ON core.production_activity(course_id); 

CREATE INDEX IF NOT EXISTS ix_integration_course ON core.course_integration(course_id); 

CREATE INDEX IF NOT EXISTS ix_redeveloped_course ON core.redeveloped_course_response(course_id); 

  

COMMIT;