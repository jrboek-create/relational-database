-- Directus Relational Repository
-- Gate 4.2: Create Reporting Structures
--
-- COMPLETE CORRECTED COMMIT VERSION
--
-- Authorized persistent objects only:
--   1. reporting schema
--   2. reporting.projection_refresh_run
--   3. reporting.course_current_catalog
--
-- Gate 4.1 prerequisite: PASS
--
-- Validated Gate 4.1 SQL SHA-256:
-- CADC8B20258EF21F6D90B0069FB0D087B1301D85A8F4D7124C3A3C66F653AE46
--
-- Frozen Gate 4.1 candidate business checksum:
-- 666d67d56d4c492ea0cdd7a63a7f85fd
--
-- Frozen Gate 4.1 baseline:
--   Current WW_CATALOG Courses:     966
--   Distinct course_id:             966
--   Required-field failures:        0
--   Duplicate source-ID groups:     0
--   Second-batch lineage:           5
--   Prior-batch lineage:            961
--   Other-batch lineage:            0
--
-- This script does NOT:
--   * populate reporting tables;
--   * modify core.* objects;
--   * modify staging.* objects;
--   * query raw staging data;
--   * rerun Gate 3 promotion;
--   * configure Directus;
--   * implement Gate 4.3 refresh logic.
--
-- Gate 4.2 creates reporting structures only.

\set ON_ERROR_STOP on

BEGIN;


-- ===========================================================================
-- 1. CLEAN-ENTRY PROTECTION
-- ===========================================================================

DO $gate4_2_entry$
BEGIN

    IF to_regnamespace('reporting') IS NOT NULL THEN

        RAISE EXCEPTION
            'Gate 4.2 safety stop: schema reporting already exists.';

    END IF;

END
$gate4_2_entry$;


-- ===========================================================================
-- 2. AUTHORIZED REPORTING SCHEMA
-- ===========================================================================

CREATE SCHEMA reporting;


-- ===========================================================================
-- 3. REPORTING REFRESH-RUN CONTROL TABLE
--
-- Technical reporting infrastructure.
-- This is not a business entity.
--
-- Lifecycle:
--
--     STARTED
--        |
--        +----> COMPLETED
--        |
--        +----> FAILED
--
-- Final refresh metrics are intentionally nullable while a run is STARTED.
-- Gate 4.2 creates no refresh-run rows.
-- ===========================================================================

CREATE TABLE reporting.projection_refresh_run
(
    run_id              uuid        NOT NULL
                                    DEFAULT gen_random_uuid(),

    projection_name     text        NOT NULL,

    started_at          timestamptz NOT NULL
                                    DEFAULT clock_timestamp(),

    completed_at        timestamptz,

    source_filter       jsonb       NOT NULL,

    source_state        jsonb       NOT NULL,

    source_row_count    bigint,

    rows_inserted       bigint,

    rows_updated        bigint,

    rows_deleted        bigint,

    rows_unchanged      bigint,

    business_checksum   text,

    status              text        NOT NULL
                                    DEFAULT 'STARTED',

    notes               text,

    error_information   text,


    CONSTRAINT projection_refresh_run_pkey
        PRIMARY KEY (run_id),


    CONSTRAINT ck_projection_refresh_run_projection_name
        CHECK
        (
            btrim(projection_name) <> ''
        ),


    CONSTRAINT ck_projection_refresh_run_source_filter_object
        CHECK
        (
            jsonb_typeof(source_filter) = 'object'
        ),


    CONSTRAINT ck_projection_refresh_run_source_state_object
        CHECK
        (
            jsonb_typeof(source_state) = 'object'
        ),


    CONSTRAINT ck_projection_refresh_run_nonnegative_counts
        CHECK
        (
            (source_row_count IS NULL OR source_row_count >= 0)

            AND

            (rows_inserted IS NULL OR rows_inserted >= 0)

            AND

            (rows_updated IS NULL OR rows_updated >= 0)

            AND

            (rows_deleted IS NULL OR rows_deleted >= 0)

            AND

            (rows_unchanged IS NULL OR rows_unchanged >= 0)
        ),


    CONSTRAINT ck_projection_refresh_run_time_order
        CHECK
        (
            completed_at IS NULL
            OR completed_at >= started_at
        ),


    CONSTRAINT ck_projection_refresh_run_checksum
        CHECK
        (
            business_checksum IS NULL
            OR btrim(business_checksum) <> ''
        ),


    CONSTRAINT ck_projection_refresh_run_status
        CHECK
        (
            status IN
            (
                'STARTED',
                'COMPLETED',
                'FAILED'
            )
        ),


    CONSTRAINT ck_projection_refresh_run_lifecycle
        CHECK
        (
            (
                status = 'STARTED'

                AND completed_at IS NULL

                AND rows_inserted IS NULL

                AND rows_updated IS NULL

                AND rows_deleted IS NULL

                AND rows_unchanged IS NULL

                AND business_checksum IS NULL

                AND error_information IS NULL
            )

            OR

            (
                status = 'COMPLETED'

                AND completed_at IS NOT NULL

                AND source_row_count IS NOT NULL

                AND rows_inserted IS NOT NULL

                AND rows_updated IS NOT NULL

                AND rows_deleted IS NOT NULL

                AND rows_unchanged IS NOT NULL

                AND business_checksum IS NOT NULL

                AND btrim(business_checksum) <> ''

                AND error_information IS NULL
            )

            OR

            (
                status = 'FAILED'

                AND completed_at IS NOT NULL

                AND error_information IS NOT NULL

                AND btrim(error_information) <> ''
            )
        )
);


-- ===========================================================================
-- 4. CURRENT WORLDWIDE COURSE CATALOG REPORTING PROJECTION
--
-- Grain:
--     One row per current WW_CATALOG Course.
--
-- Stable identity:
--     course_id reuses core.course.course_id.
--
-- No second Course identity is created.
--
-- Gate 4.2 creates the EMPTY structure only.
-- ===========================================================================

CREATE TABLE reporting.course_current_catalog
(
    course_id              uuid        NOT NULL,

    university_course_id   text        NOT NULL,

    course_code             text        NOT NULL,

    course_title            text        NOT NULL,

    source_system_code      text        NOT NULL,

    core_import_batch_id    uuid        NOT NULL,

    source_record_locator   text        NOT NULL,

    source_version_label    text        NOT NULL,

    report_refresh_run_id   uuid        NOT NULL,

    report_as_of_utc        timestamptz NOT NULL,

    business_row_hash       text        NOT NULL,


    CONSTRAINT course_current_catalog_pkey
        PRIMARY KEY (course_id),


    CONSTRAINT course_current_catalog_refresh_run_fkey
        FOREIGN KEY (report_refresh_run_id)
        REFERENCES reporting.projection_refresh_run(run_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,


    CONSTRAINT ck_course_current_catalog_university_course_id
        CHECK
        (
            btrim(university_course_id) <> ''
        ),


    CONSTRAINT ck_course_current_catalog_course_code
        CHECK
        (
            btrim(course_code) <> ''
        ),


    CONSTRAINT ck_course_current_catalog_course_title
        CHECK
        (
            btrim(course_title) <> ''
        ),


    CONSTRAINT ck_course_current_catalog_source_system
        CHECK
        (
            source_system_code = 'WW_CATALOG'
        ),


    CONSTRAINT ck_course_current_catalog_source_locator
        CHECK
        (
            btrim(source_record_locator) <> ''
        ),


    CONSTRAINT ck_course_current_catalog_source_version
        CHECK
        (
            btrim(source_version_label) <> ''
        ),


    CONSTRAINT ck_course_current_catalog_business_hash
        CHECK
        (
            btrim(business_row_hash) <> ''
        )
);


-- ===========================================================================
-- 5. STRUCTURAL, CONSTRAINT, EMPTY-STATE, AND FROZEN-CORE VALIDATION
--
-- This anonymous DO block creates no persistent function or procedure.
--
-- Any failed assertion raises an exception.
-- With ON_ERROR_STOP enabled, execution stops and the transaction cannot
-- successfully reach COMMIT.
-- ===========================================================================

DO $gate4_2_validate$

DECLARE

    v_structure_errors        text;

    v_constraint_errors       text;

    v_status_definition       text;

    v_lifecycle_definition    text;

    v_unauthorized_relations  bigint;

    v_unauthorized_indexes    bigint;

    v_unauthorized_triggers   bigint;

    v_unauthorized_policies   bigint;

    v_reporting_routines      bigint;

    v_projection_rows         bigint;

    v_refresh_rows            bigint;

    v_source_identity         bigint;

    v_current_rows            bigint;

    v_distinct_course_ids     bigint;

    v_required_failures       bigint;

    v_duplicate_source_groups bigint;

    v_second_rows             bigint;

    v_prior_rows              bigint;

    v_other_rows              bigint;

    v_second_promoted         bigint;

    v_prior_promoted          bigint;

    v_candidate_rows          bigint;

    v_candidate_distinct_ids  bigint;

    v_candidate_checksum      text;

BEGIN


    -- =======================================================================
    -- 5.1 EXACT COLUMN STRUCTURE
    -- =======================================================================

    WITH expected
    (
        table_name,
        ordinal_position,
        column_name,
        data_type,
        is_nullable
    )
    AS
    (
        VALUES

        ('projection_refresh_run',1,'run_id','uuid','NO'),

        ('projection_refresh_run',2,'projection_name','text','NO'),

        ('projection_refresh_run',3,'started_at',
            'timestamp with time zone','NO'),

        ('projection_refresh_run',4,'completed_at',
            'timestamp with time zone','YES'),

        ('projection_refresh_run',5,'source_filter','jsonb','NO'),

        ('projection_refresh_run',6,'source_state','jsonb','NO'),

        ('projection_refresh_run',7,'source_row_count','bigint','YES'),

        ('projection_refresh_run',8,'rows_inserted','bigint','YES'),

        ('projection_refresh_run',9,'rows_updated','bigint','YES'),

        ('projection_refresh_run',10,'rows_deleted','bigint','YES'),

        ('projection_refresh_run',11,'rows_unchanged','bigint','YES'),

        ('projection_refresh_run',12,'business_checksum','text','YES'),

        ('projection_refresh_run',13,'status','text','NO'),

        ('projection_refresh_run',14,'notes','text','YES'),

        ('projection_refresh_run',15,'error_information','text','YES'),


        ('course_current_catalog',1,'course_id','uuid','NO'),

        ('course_current_catalog',2,'university_course_id','text','NO'),

        ('course_current_catalog',3,'course_code','text','NO'),

        ('course_current_catalog',4,'course_title','text','NO'),

        ('course_current_catalog',5,'source_system_code','text','NO'),

        ('course_current_catalog',6,'core_import_batch_id','uuid','NO'),

        ('course_current_catalog',7,'source_record_locator','text','NO'),

        ('course_current_catalog',8,'source_version_label','text','NO'),

        ('course_current_catalog',9,'report_refresh_run_id','uuid','NO'),

        ('course_current_catalog',10,'report_as_of_utc',
            'timestamp with time zone','NO'),

        ('course_current_catalog',11,'business_row_hash','text','NO')
    ),

    actual
    AS
    (
        SELECT
            table_name,
            ordinal_position,
            column_name,
            data_type,
            is_nullable

        FROM information_schema.columns

        WHERE table_schema = 'reporting'

          AND table_name IN
          (
              'projection_refresh_run',
              'course_current_catalog'
          )
    ),

    differences
    AS
    (
        SELECT

            coalesce
            (
                e.table_name,
                a.table_name
            ) AS table_name,

            coalesce
            (
                e.column_name,
                a.column_name
            ) AS column_name

        FROM expected e

        FULL JOIN actual a

          ON a.table_name = e.table_name

         AND a.ordinal_position = e.ordinal_position

         AND a.column_name = e.column_name

        WHERE e.table_name IS NULL

           OR a.table_name IS NULL

           OR e.data_type IS DISTINCT FROM a.data_type

           OR e.is_nullable IS DISTINCT FROM a.is_nullable
    )

    SELECT

        string_agg
        (
            format
            (
                '%s.%s',
                table_name,
                column_name
            ),

            ', '

            ORDER BY
                table_name,
                column_name
        )

    INTO v_structure_errors

    FROM differences;


    IF v_structure_errors IS NOT NULL THEN

        RAISE EXCEPTION
            'Gate 4.2 column-definition failure: %',
            v_structure_errors;

    END IF;


    -- =======================================================================
    -- 5.2 REQUIRED DEFAULTS
    -- =======================================================================

    IF NOT EXISTS
    (
        SELECT 1

        FROM information_schema.columns

        WHERE table_schema = 'reporting'

          AND table_name = 'projection_refresh_run'

          AND column_name = 'run_id'

          AND column_default LIKE '%gen_random_uuid%'
    )
    THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: run_id UUID default is missing.';

    END IF;


    IF NOT EXISTS
    (
        SELECT 1

        FROM information_schema.columns

        WHERE table_schema = 'reporting'

          AND table_name = 'projection_refresh_run'

          AND column_name = 'started_at'

          AND column_default LIKE '%clock_timestamp%'
    )
    THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: started_at default is missing.';

    END IF;


    IF NOT EXISTS
    (
        SELECT 1

        FROM information_schema.columns

        WHERE table_schema = 'reporting'

          AND table_name = 'projection_refresh_run'

          AND column_name = 'status'

          AND column_default LIKE '%STARTED%'
    )
    THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: status STARTED default is missing.';

    END IF;


    -- =======================================================================
    -- 5.3 EXACT CONSTRAINT SET
    -- =======================================================================

    WITH expected
    (
        table_name,
        constraint_name,
        constraint_type
    )
    AS
    (
        VALUES

        ('projection_refresh_run',
         'projection_refresh_run_pkey',
         'p'),

        ('projection_refresh_run',
         'ck_projection_refresh_run_projection_name',
         'c'),

        ('projection_refresh_run',
         'ck_projection_refresh_run_source_filter_object',
         'c'),

        ('projection_refresh_run',
         'ck_projection_refresh_run_source_state_object',
         'c'),

        ('projection_refresh_run',
         'ck_projection_refresh_run_nonnegative_counts',
         'c'),

        ('projection_refresh_run',
         'ck_projection_refresh_run_time_order',
         'c'),

        ('projection_refresh_run',
         'ck_projection_refresh_run_checksum',
         'c'),

        ('projection_refresh_run',
         'ck_projection_refresh_run_status',
         'c'),

        ('projection_refresh_run',
         'ck_projection_refresh_run_lifecycle',
         'c'),


        ('course_current_catalog',
         'course_current_catalog_pkey',
         'p'),

        ('course_current_catalog',
         'course_current_catalog_refresh_run_fkey',
         'f'),

        ('course_current_catalog',
         'ck_course_current_catalog_university_course_id',
         'c'),

        ('course_current_catalog',
         'ck_course_current_catalog_course_code',
         'c'),

        ('course_current_catalog',
         'ck_course_current_catalog_course_title',
         'c'),

        ('course_current_catalog',
         'ck_course_current_catalog_source_system',
         'c'),

        ('course_current_catalog',
         'ck_course_current_catalog_source_locator',
         'c'),

        ('course_current_catalog',
         'ck_course_current_catalog_source_version',
         'c'),

        ('course_current_catalog',
         'ck_course_current_catalog_business_hash',
         'c')
    ),

    actual
    AS
    (
        SELECT

            cls.relname::text
                AS table_name,

            con.conname::text
                AS constraint_name,

            con.contype::text
                AS constraint_type

        FROM pg_constraint con

        JOIN pg_class cls
          ON cls.oid = con.conrelid

        JOIN pg_namespace nsp
          ON nsp.oid = cls.relnamespace

        WHERE nsp.nspname = 'reporting'

          AND cls.relname IN
          (
              'projection_refresh_run',
              'course_current_catalog'
          )

          AND con.contype IN
          (
              'p',
              'f',
              'c'
          )
    ),

    differences
    AS
    (
        SELECT

            CASE

                WHEN e.constraint_name IS NULL
                THEN format
                (
                    'UNEXPECTED %s.%s type=%s',
                    a.table_name,
                    a.constraint_name,
                    a.constraint_type
                )

                WHEN a.constraint_name IS NULL
                THEN format
                (
                    'MISSING %s.%s expected_type=%s',
                    e.table_name,
                    e.constraint_name,
                    e.constraint_type
                )

                ELSE format
                (
                    'TYPE_MISMATCH %s.%s expected=%s actual=%s',
                    e.table_name,
                    e.constraint_name,
                    e.constraint_type,
                    a.constraint_type
                )

            END AS issue

        FROM expected e

        FULL JOIN actual a

          ON a.table_name = e.table_name

         AND a.constraint_name = e.constraint_name

        WHERE e.constraint_name IS NULL

           OR a.constraint_name IS NULL

           OR e.constraint_type IS DISTINCT FROM a.constraint_type
    )

    SELECT

        string_agg
        (
            issue,
            '; '
            ORDER BY issue
        )

    INTO v_constraint_errors

    FROM differences;


    IF v_constraint_errors IS NOT NULL THEN

        RAISE EXCEPTION
            'Gate 4.2 exact constraint-set failure: %',
            v_constraint_errors;

    END IF;


    -- =======================================================================
    -- 5.4 ALL CHECK/FK CONSTRAINTS MUST BE VALIDATED
    -- =======================================================================

    IF EXISTS
    (
        SELECT 1

        FROM pg_constraint con

        WHERE con.conrelid IN
        (
            'reporting.projection_refresh_run'::regclass,
            'reporting.course_current_catalog'::regclass
        )

          AND con.contype IN
          (
              'c',
              'f'
          )

          AND con.convalidated IS NOT TRUE
    )
    THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: one or more reporting CHECK/FK constraints are not validated.';

    END IF;


    -- =======================================================================
    -- 5.5 EXACT PRIMARY-KEY COLUMNS
    -- =======================================================================

    IF NOT EXISTS
    (
        SELECT 1

        FROM pg_constraint con

        WHERE con.conname =
              'projection_refresh_run_pkey'

          AND con.conrelid =
              'reporting.projection_refresh_run'::regclass

          AND con.contype = 'p'

          AND con.conkey =
              ARRAY
              [
                  (
                      SELECT attnum

                      FROM pg_attribute

                      WHERE attrelid =
                            'reporting.projection_refresh_run'::regclass

                        AND attname = 'run_id'

                        AND attisdropped IS FALSE
                  )
              ]::smallint[]

          AND con.condeferrable IS FALSE

          AND con.condeferred IS FALSE
    )
    THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: projection_refresh_run PK is not exactly run_id.';

    END IF;


    IF NOT EXISTS
    (
        SELECT 1

        FROM pg_constraint con

        WHERE con.conname =
              'course_current_catalog_pkey'

          AND con.conrelid =
              'reporting.course_current_catalog'::regclass

          AND con.contype = 'p'

          AND con.conkey =
              ARRAY
              [
                  (
                      SELECT attnum

                      FROM pg_attribute

                      WHERE attrelid =
                            'reporting.course_current_catalog'::regclass

                        AND attname = 'course_id'

                        AND attisdropped IS FALSE
                  )
              ]::smallint[]

          AND con.condeferrable IS FALSE

          AND con.condeferred IS FALSE
    )
    THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: course_current_catalog PK is not exactly course_id.';

    END IF;


    -- =======================================================================
    -- 5.6 EXACT REFRESH-RUN FOREIGN KEY
    --
    -- course_current_catalog.report_refresh_run_id
    --     -> projection_refresh_run.run_id
    --
    -- MATCH SIMPLE
    -- ON UPDATE RESTRICT
    -- ON DELETE RESTRICT
    -- NOT DEFERRABLE
    -- =======================================================================

    IF NOT EXISTS
    (
        SELECT 1

        FROM pg_constraint con

        WHERE con.conname =
              'course_current_catalog_refresh_run_fkey'

          AND con.conrelid =
              'reporting.course_current_catalog'::regclass

          AND con.confrelid =
              'reporting.projection_refresh_run'::regclass

          AND con.contype = 'f'

          AND con.conkey =
              ARRAY
              [
                  (
                      SELECT attnum

                      FROM pg_attribute

                      WHERE attrelid =
                            'reporting.course_current_catalog'::regclass

                        AND attname = 'report_refresh_run_id'

                        AND attisdropped IS FALSE
                  )
              ]::smallint[]

          AND con.confkey =
              ARRAY
              [
                  (
                      SELECT attnum

                      FROM pg_attribute

                      WHERE attrelid =
                            'reporting.projection_refresh_run'::regclass

                        AND attname = 'run_id'

                        AND attisdropped IS FALSE
                  )
              ]::smallint[]

          AND con.confmatchtype = 's'

          AND con.confupdtype = 'r'

          AND con.confdeltype = 'r'

          AND con.condeferrable IS FALSE

          AND con.condeferred IS FALSE

          AND con.convalidated IS TRUE
    )
    THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: refresh-run FK definition or referential actions are incorrect.';

    END IF;


    -- =======================================================================
    -- 5.7 STATUS CHECK DEFINITION
    --
    -- Normalize PostgreSQL's deparsed CHECK expression and verify that the
    -- approved three lifecycle states are present and no additional quoted
    -- status values are present.
    -- =======================================================================

    SELECT

        replace
        (
            lower
            (
                regexp_replace
                (
                    pg_get_constraintdef
                    (
                        con.oid,
                        false
                    ),

                    E'\\s+',
                    '',
                    'g'
                )
            ),

            '::text',
            ''
        )

    INTO v_status_definition

    FROM pg_constraint con

    WHERE con.conname =
          'ck_projection_refresh_run_status'

      AND con.conrelid =
          'reporting.projection_refresh_run'::regclass

      AND con.contype = 'c';


    IF v_status_definition IS NULL

       OR position
          (
              '''started'''
              IN v_status_definition
          ) = 0

       OR position
          (
              '''completed'''
              IN v_status_definition
          ) = 0

       OR position
          (
              '''failed'''
              IN v_status_definition
          ) = 0

       OR regexp_count
          (
              v_status_definition,
              '''started'''
          ) <> 1

       OR regexp_count
          (
              v_status_definition,
              '''completed'''
          ) <> 1

       OR regexp_count
          (
              v_status_definition,
              '''failed'''
          ) <> 1
    THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: status CHECK differs from the approved STARTED/COMPLETED/FAILED definition. Observed: %',
            coalesce
            (
                v_status_definition,
                '<NULL>'
            );

    END IF;


    -- =======================================================================
    -- 5.8 LIFECYCLE CHECK DEFINITION
    --
    -- Validate the PostgreSQL-deparsed lifecycle CHECK rather than relying
    -- only on its name or the number of CHECK constraints.
    -- =======================================================================

    SELECT

        replace
        (
            lower
            (
                regexp_replace
                (
                    pg_get_constraintdef
                    (
                        con.oid,
                        false
                    ),

                    E'\\s+',
                    '',
                    'g'
                )
            ),

            '::text',
            ''
        )

    INTO v_lifecycle_definition

    FROM pg_constraint con

    WHERE con.conname =
          'ck_projection_refresh_run_lifecycle'

      AND con.conrelid =
          'reporting.projection_refresh_run'::regclass

      AND con.contype = 'c';


    IF v_lifecycle_definition IS NULL

       OR regexp_count
          (
              v_lifecycle_definition,
              'status='
          ) <> 3

       OR position
          (
              'status=''started'''
              IN v_lifecycle_definition
          ) = 0

       OR position
          (
              'status=''completed'''
              IN v_lifecycle_definition
          ) = 0

       OR position
          (
              'status=''failed'''
              IN v_lifecycle_definition
          ) = 0

       OR regexp_count
          (
              v_lifecycle_definition,
              'completed_atisnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'completed_atisnotnull'
          ) <> 2

       OR regexp_count
          (
              v_lifecycle_definition,
              'rows_insertedisnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'rows_insertedisnotnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'rows_updatedisnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'rows_updatedisnotnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'rows_deletedisnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'rows_deletedisnotnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'rows_unchangedisnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'rows_unchangedisnotnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'source_row_countisnotnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'business_checksumisnull'
          ) <> 1

       OR regexp_count
          (
              v_lifecycle_definition,
              'business_checksumisnotnull'
          ) <> 1

       OR position
          (
              'btrim(business_checksum)<>'''''
              IN v_lifecycle_definition
          ) = 0

       OR regexp_count
          (
              v_lifecycle_definition,
              'error_informationisnull'
          ) <> 2

       OR regexp_count
          (
              v_lifecycle_definition,
              'error_informationisnotnull'
          ) <> 1

       OR position
          (
              'btrim(error_information)<>'''''
              IN v_lifecycle_definition
          ) = 0
    THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: lifecycle CHECK differs from the approved STARTED/COMPLETED/FAILED controls. Observed: %',
            coalesce
            (
                v_lifecycle_definition,
                '<NULL>'
            );

    END IF;


    -- =======================================================================
    -- 5.9 NO UNAUTHORIZED REPORTING RELATIONS
    --
    -- Constraint-backed indexes are implementation artifacts and are not
    -- counted here as independent reporting relations.
    -- =======================================================================

    SELECT count(*)

    INTO v_unauthorized_relations

    FROM pg_class c

    JOIN pg_namespace n
      ON n.oid = c.relnamespace

    WHERE n.nspname = 'reporting'

      AND c.relkind IN
      (
          'r',
          'p',
          'v',
          'm',
          'S',
          'f'
      )

      AND c.relname NOT IN
      (
          'projection_refresh_run',
          'course_current_catalog'
      );


    IF v_unauthorized_relations <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: % unauthorized reporting relations.',
            v_unauthorized_relations;

    END IF;


    -- =======================================================================
    -- 5.10 NO UNAUTHORIZED STANDALONE INDEXES
    --
    -- Primary-key indexes created automatically by PostgreSQL are allowed.
    -- Any other reporting index is outside Gate 4.2 scope.
    -- =======================================================================

    SELECT count(*)

    INTO v_unauthorized_indexes

    FROM pg_class idx

    JOIN pg_namespace n
      ON n.oid = idx.relnamespace

    WHERE n.nspname = 'reporting'

      AND idx.relkind = 'i'

      AND NOT EXISTS
      (
          SELECT 1

          FROM pg_constraint con

          WHERE con.conindid = idx.oid

            AND con.contype IN
            (
                'p',
                'u'
            )
      );


    IF v_unauthorized_indexes <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: % unauthorized standalone reporting indexes.',
            v_unauthorized_indexes;

    END IF;


    -- =======================================================================
    -- 5.11 NO UNAUTHORIZED USER TRIGGERS
    -- =======================================================================

    SELECT count(*)

    INTO v_unauthorized_triggers

    FROM pg_trigger trg

    JOIN pg_class cls
      ON cls.oid = trg.tgrelid

    JOIN pg_namespace n
      ON n.oid = cls.relnamespace

    WHERE n.nspname = 'reporting'

      AND trg.tgisinternal IS FALSE;


    IF v_unauthorized_triggers <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: % unauthorized reporting triggers.',
            v_unauthorized_triggers;

    END IF;


    -- =======================================================================
    -- 5.12 NO ROW-SECURITY POLICIES
    -- =======================================================================

    SELECT count(*)

    INTO v_unauthorized_policies

    FROM pg_policy pol

    JOIN pg_class cls
      ON cls.oid = pol.polrelid

    JOIN pg_namespace n
      ON n.oid = cls.relnamespace

    WHERE n.nspname = 'reporting';


    IF v_unauthorized_policies <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: % unauthorized reporting policies.',
            v_unauthorized_policies;

    END IF;


    -- =======================================================================
    -- 5.13 NO PERSISTENT REPORTING ROUTINES
    -- =======================================================================

    SELECT count(*)

    INTO v_reporting_routines

    FROM pg_proc p

    JOIN pg_namespace n
      ON n.oid = p.pronamespace

    WHERE n.nspname = 'reporting';


    IF v_reporting_routines <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.2 failure: persistent reporting routines exist.';

    END IF;


    -- =======================================================================
    -- 5.14 BOTH REPORTING TABLES MUST REMAIN EMPTY
    -- =======================================================================

    SELECT count(*)

    INTO v_projection_rows

    FROM reporting.course_current_catalog;


    SELECT count(*)

    INTO v_refresh_rows

    FROM reporting.projection_refresh_run;


    IF v_projection_rows <> 0
       OR v_refresh_rows <> 0
    THEN

        RAISE EXCEPTION
            'Gate 4.2 empty-state failure: projection %, refresh runs %.',
            v_projection_rows,
            v_refresh_rows;

    END IF;


    -- =======================================================================
    -- 5.15 WW_CATALOG SOURCE IDENTITY
    -- =======================================================================

    SELECT count(*)

    INTO v_source_identity

    FROM core.source_system

    WHERE system_code = 'WW_CATALOG'

      AND source_system_id =
          'a5d205bc-fd64-4d07-b437-c4440425be42'::uuid;


    IF v_source_identity <> 1 THEN

        RAISE EXCEPTION
            'Gate 4.2 source identity failure: expected 1, found %.',
            v_source_identity;

    END IF;


    -- =======================================================================
    -- 5.16 FROZEN CURRENT-CORE BASELINE
    -- =======================================================================

    SELECT

        count(*),

        count(DISTINCT c.course_id),

        count(*) FILTER
        (
            WHERE c.course_id IS NULL

               OR c.source_identifier IS NULL

               OR btrim(c.source_identifier) = ''

               OR c.course_code IS NULL

               OR btrim(c.course_code) = ''

               OR c.course_title IS NULL

               OR btrim(c.course_title) = ''

               OR c.import_batch_id IS NULL

               OR c.source_record_locator IS NULL

               OR btrim(c.source_record_locator) = ''

               OR c.source_version_label IS NULL

               OR btrim(c.source_version_label) = ''
        )

    INTO

        v_current_rows,

        v_distinct_course_ids,

        v_required_failures

    FROM core.course c

    JOIN core.import_batch ib
      ON ib.import_batch_id = c.import_batch_id

    JOIN core.source_system ss
      ON ss.source_system_id = ib.source_system_id

    WHERE ss.system_code = 'WW_CATALOG'

      AND c.is_current IS TRUE;


    -- =======================================================================
    -- 5.17 DUPLICATE SOURCE IDENTIFIERS
    -- =======================================================================

    SELECT count(*)

    INTO v_duplicate_source_groups

    FROM
    (
        SELECT
            c.source_identifier

        FROM core.course c

        JOIN core.import_batch ib
          ON ib.import_batch_id = c.import_batch_id

        JOIN core.source_system ss
          ON ss.source_system_id = ib.source_system_id

        WHERE ss.system_code = 'WW_CATALOG'

          AND c.is_current IS TRUE

        GROUP BY
            c.source_identifier

        HAVING count(*) > 1

    ) duplicate_groups;


    -- =======================================================================
    -- 5.18 FROZEN IMPORT-BATCH LINEAGE
    -- =======================================================================

    SELECT

        count(*) FILTER
        (
            WHERE c.import_batch_id =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
        ),

        count(*) FILTER
        (
            WHERE c.import_batch_id =
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
        ),

        count(*) FILTER
        (
            WHERE c.import_batch_id NOT IN
            (
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,

              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
            )
        )

    INTO

        v_second_rows,

        v_prior_rows,

        v_other_rows

    FROM core.course c

    JOIN core.import_batch ib
      ON ib.import_batch_id = c.import_batch_id

    JOIN core.source_system ss
      ON ss.source_system_id = ib.source_system_id

    WHERE ss.system_code = 'WW_CATALOG'

      AND c.is_current IS TRUE;


    -- =======================================================================
    -- 5.19 GATE 3 IMPORT-BATCH LIFECYCLE
    -- =======================================================================

    SELECT

        count(*) FILTER
        (
            WHERE import_batch_id =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid

              AND upper(batch_status) = 'PROMOTED'
        ),

        count(*) FILTER
        (
            WHERE import_batch_id =
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid

              AND upper(batch_status) = 'PROMOTED'
        )

    INTO

        v_second_promoted,

        v_prior_promoted

    FROM core.import_batch;


    -- =======================================================================
    -- 5.20 FROZEN GATE 4.1 CANDIDATE CHECKSUM ALGORITHM
    --
    -- Source:
    -- sql\gate4\000_preflight_course_current_catalog.sql
    --
    -- Validated Gate 4.1 SQL SHA-256:
    -- CADC8B20258EF21F6D90B0069FB0D087B1301D85A8F4D7124C3A3C66F653AE46
    --
    -- Frozen Gate 4.1 candidate checksum:
    -- 666d67d56d4c492ea0cdd7a63a7f85fd
    -- =======================================================================

    WITH candidate AS
    (
        SELECT

            c.course_id,

            c.source_identifier
                AS university_course_id,

            c.course_code,

            md5
            (
                concat_ws
                (
                    E'\x1f',

                    coalesce
                    (
                        c.source_identifier,
                        ''
                    ),

                    coalesce
                    (
                        c.course_code,
                        ''
                    ),

                    coalesce
                    (
                        c.course_title,
                        ''
                    ),

                    coalesce
                    (
                        ss.system_code,
                        ''
                    ),

                    coalesce
                    (
                        c.import_batch_id::text,
                        ''
                    ),

                    coalesce
                    (
                        c.source_record_locator,
                        ''
                    ),

                    coalesce
                    (
                        c.source_version_label,
                        ''
                    )
                )
            )
            AS business_row_hash

        FROM core.course c

        JOIN core.import_batch ib
          ON ib.import_batch_id = c.import_batch_id

        JOIN core.source_system ss
          ON ss.source_system_id = ib.source_system_id

        WHERE ss.system_code = 'WW_CATALOG'

          AND c.is_current IS TRUE
    )

    SELECT

        count(*),

        count(DISTINCT course_id),

        md5
        (
            string_agg
            (
                business_row_hash,

                ''

                ORDER BY

                    course_code COLLATE "C",

                    university_course_id COLLATE "C",

                    course_id
            )
        )

    INTO

        v_candidate_rows,

        v_candidate_distinct_ids,

        v_candidate_checksum

    FROM candidate;


    -- =======================================================================
    -- 5.21 FINAL ASSERTIONS
    -- =======================================================================

    IF v_current_rows <> 966 THEN

        RAISE EXCEPTION
            'Gate 4.2 core count failure: expected 966, found %.',
            v_current_rows;


    ELSIF v_distinct_course_ids <> 966 THEN

        RAISE EXCEPTION
            'Gate 4.2 Course UUID failure: expected 966, found %.',
            v_distinct_course_ids;


    ELSIF v_required_failures <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.2 required-field failure count: %.',
            v_required_failures;


    ELSIF v_duplicate_source_groups <> 0 THEN

        RAISE EXCEPTION
            'Gate 4.2 duplicate source-ID groups: %.',
            v_duplicate_source_groups;


    ELSIF v_second_rows <> 5

       OR v_prior_rows <> 961

       OR v_other_rows <> 0
    THEN

        RAISE EXCEPTION
            'Gate 4.2 lineage failure: second %, prior %, other %.',
            v_second_rows,
            v_prior_rows,
            v_other_rows;


    ELSIF v_second_promoted <> 1

       OR v_prior_promoted <> 1
    THEN

        RAISE EXCEPTION
            'Gate 4.2 lifecycle failure: second %, prior %.',
            v_second_promoted,
            v_prior_promoted;


    ELSIF v_candidate_rows <> 966

       OR v_candidate_distinct_ids <> 966
    THEN

        RAISE EXCEPTION
            'Gate 4.2 candidate failure: rows %, distinct IDs %.',
            v_candidate_rows,
            v_candidate_distinct_ids;


    ELSIF v_candidate_checksum IS DISTINCT FROM
          '666d67d56d4c492ea0cdd7a63a7f85fd'
    THEN

        RAISE EXCEPTION
            'Gate 4.2 checksum failure: expected %, found %.',
            '666d67d56d4c492ea0cdd7a63a7f85fd',
            coalesce
            (
                v_candidate_checksum,
                '<NULL>'
            );

    END IF;


    RAISE NOTICE
        'Gate 4.2 validation PASS: structures valid, exact constraints valid, tables empty, core unchanged, checksum preserved.';

END

$gate4_2_validate$;


-- ===========================================================================
-- 6. REVIEWABLE STRUCTURAL EVIDENCE
-- ===========================================================================

SELECT

    table_schema,

    table_name,

    ordinal_position,

    column_name,

    data_type,

    is_nullable,

    column_default

FROM information_schema.columns

WHERE table_schema = 'reporting'

ORDER BY
    table_name,
    ordinal_position;


-- ===========================================================================
-- 7. REVIEWABLE CONSTRAINT EVIDENCE
-- ===========================================================================

SELECT

    c.relname AS table_name,

    con.conname AS constraint_name,

    CASE con.contype

        WHEN 'p'
            THEN 'PRIMARY KEY'

        WHEN 'f'
            THEN 'FOREIGN KEY'

        WHEN 'c'
            THEN 'CHECK'

        ELSE con.contype::text

    END AS constraint_type,

    con.convalidated,

    con.condeferrable,

    con.condeferred,

    pg_get_constraintdef
    (
        con.oid,
        true
    ) AS definition

FROM pg_constraint con

JOIN pg_class c
  ON c.oid = con.conrelid

JOIN pg_namespace n
  ON n.oid = c.relnamespace

WHERE n.nspname = 'reporting'

ORDER BY
    c.relname,
    constraint_type,
    con.conname;


-- ===========================================================================
-- 8. RECOMPUTED GATE 4.2 EVIDENCE
--
-- Unlike the earlier draft, this section does not merely print frozen
-- baseline literals as though they were observed values.
--
-- It recomputes the live core state and presents expected versus observed.
-- ===========================================================================

WITH candidate AS
(
    SELECT

        c.course_id,

        c.source_identifier
            AS university_course_id,

        c.course_code,

        md5
        (
            concat_ws
            (
                E'\x1f',

                coalesce
                (
                    c.source_identifier,
                    ''
                ),

                coalesce
                (
                    c.course_code,
                    ''
                ),

                coalesce
                (
                    c.course_title,
                    ''
                ),

                coalesce
                (
                    ss.system_code,
                    ''
                ),

                coalesce
                (
                    c.import_batch_id::text,
                    ''
                ),

                coalesce
                (
                    c.source_record_locator,
                    ''
                ),

                coalesce
                (
                    c.source_version_label,
                    ''
                )
            )
        )
        AS business_row_hash

    FROM core.course c

    JOIN core.import_batch ib
      ON ib.import_batch_id = c.import_batch_id

    JOIN core.source_system ss
      ON ss.source_system_id = ib.source_system_id

    WHERE ss.system_code = 'WW_CATALOG'

      AND c.is_current IS TRUE
),

core_metrics AS
(
    SELECT

        count(*) AS current_rows,

        count(DISTINCT c.course_id)
            AS distinct_course_ids,

        count(*) FILTER
        (
            WHERE c.course_id IS NULL

               OR c.source_identifier IS NULL

               OR btrim(c.source_identifier) = ''

               OR c.course_code IS NULL

               OR btrim(c.course_code) = ''

               OR c.course_title IS NULL

               OR btrim(c.course_title) = ''

               OR c.import_batch_id IS NULL

               OR c.source_record_locator IS NULL

               OR btrim(c.source_record_locator) = ''

               OR c.source_version_label IS NULL

               OR btrim(c.source_version_label) = ''
        )
        AS required_field_failures,

        count(*) FILTER
        (
            WHERE c.import_batch_id =
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid
        )
        AS second_batch_rows,

        count(*) FILTER
        (
            WHERE c.import_batch_id =
              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
        )
        AS prior_batch_rows,

        count(*) FILTER
        (
            WHERE c.import_batch_id NOT IN
            (
              '53e0ae11-6a25-4f0a-9beb-814c8c3d1946'::uuid,

              '06b1327c-95e0-49b7-b23c-103fb0fb3b20'::uuid
            )
        )
        AS other_batch_rows

    FROM core.course c

    JOIN core.import_batch ib
      ON ib.import_batch_id = c.import_batch_id

    JOIN core.source_system ss
      ON ss.source_system_id = ib.source_system_id

    WHERE ss.system_code = 'WW_CATALOG'

      AND c.is_current IS TRUE
),

duplicate_metrics AS
(
    SELECT

        count(*) AS duplicate_source_groups

    FROM
    (
        SELECT
            c.source_identifier

        FROM core.course c

        JOIN core.import_batch ib
          ON ib.import_batch_id = c.import_batch_id

        JOIN core.source_system ss
          ON ss.source_system_id = ib.source_system_id

        WHERE ss.system_code = 'WW_CATALOG'

          AND c.is_current IS TRUE

        GROUP BY
            c.source_identifier

        HAVING count(*) > 1

    ) d
),

candidate_metrics AS
(
    SELECT

        count(*) AS candidate_rows,

        count(DISTINCT course_id)
            AS distinct_candidate_course_ids,

        md5
        (
            string_agg
            (
                business_row_hash,

                ''

                ORDER BY

                    course_code COLLATE "C",

                    university_course_id COLLATE "C",

                    course_id
            )
        )
        AS candidate_checksum

    FROM candidate
),

reporting_metrics AS
(
    SELECT

        (
            SELECT count(*)
            FROM reporting.projection_refresh_run
        )
        AS projection_refresh_run_rows,

        (
            SELECT count(*)
            FROM reporting.course_current_catalog
        )
        AS course_current_catalog_rows
)

SELECT

    966::bigint
        AS expected_current_rows,

    cm.current_rows
        AS observed_current_rows,

    966::bigint
        AS expected_distinct_course_ids,

    cm.distinct_course_ids
        AS observed_distinct_course_ids,

    0::bigint
        AS expected_required_field_failures,

    cm.required_field_failures
        AS observed_required_field_failures,

    0::bigint
        AS expected_duplicate_source_groups,

    dm.duplicate_source_groups
        AS observed_duplicate_source_groups,

    5::bigint
        AS expected_second_batch_rows,

    cm.second_batch_rows
        AS observed_second_batch_rows,

    961::bigint
        AS expected_prior_batch_rows,

    cm.prior_batch_rows
        AS observed_prior_batch_rows,

    0::bigint
        AS expected_other_batch_rows,

    cm.other_batch_rows
        AS observed_other_batch_rows,

    966::bigint
        AS expected_candidate_rows,

    cand.candidate_rows
        AS observed_candidate_rows,

    966::bigint
        AS expected_distinct_candidate_course_ids,

    cand.distinct_candidate_course_ids
        AS observed_distinct_candidate_course_ids,

    '666d67d56d4c492ea0cdd7a63a7f85fd'
        AS expected_candidate_checksum,

    cand.candidate_checksum
        AS observed_candidate_checksum,

    0::bigint
        AS expected_projection_refresh_run_rows,

    rm.projection_refresh_run_rows
        AS observed_projection_refresh_run_rows,

    0::bigint
        AS expected_course_current_catalog_rows,

    rm.course_current_catalog_rows
        AS observed_course_current_catalog_rows,

    CASE

        WHEN cm.current_rows = 966

         AND cm.distinct_course_ids = 966

         AND cm.required_field_failures = 0

         AND dm.duplicate_source_groups = 0

         AND cm.second_batch_rows = 5

         AND cm.prior_batch_rows = 961

         AND cm.other_batch_rows = 0

         AND cand.candidate_rows = 966

         AND cand.distinct_candidate_course_ids = 966

         AND cand.candidate_checksum IS NOT DISTINCT FROM
             '666d67d56d4c492ea0cdd7a63a7f85fd'

         AND rm.projection_refresh_run_rows = 0

         AND rm.course_current_catalog_rows = 0

        THEN 'PASS'

        ELSE 'FAIL'

    END AS gate_4_2_recomputed_evidence_status

FROM core_metrics cm

CROSS JOIN duplicate_metrics dm

CROSS JOIN candidate_metrics cand

CROSS JOIN reporting_metrics rm;


-- ===========================================================================
-- 9. FINAL GATE 4.2 TRANSACTION ACTION
--
-- IMPORTANT:
--
-- This is the COMMIT version.
--
-- DO NOT EXECUTE THIS VERSION YET.
--
-- The first execution will be a separately fingerprinted rehearsal copy
-- containing identical SQL except that this final statement will be:
--
--     ROLLBACK;
--
-- The COMMIT version remains frozen until the rehearsal passes.
-- ===========================================================================

COMMIT;