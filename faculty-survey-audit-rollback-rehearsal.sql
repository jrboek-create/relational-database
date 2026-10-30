\set ON_ERROR_STOP on

BEGIN;

DO $precheck$
BEGIN
    IF to_regclass('reporting.course_faculty_survey_summary') IS NOT NULL THEN
        RAISE EXCEPTION
            'Precheck failed: reporting.course_faculty_survey_summary already exists';
    END IF;

    IF to_regclass('reporting.course_faculty_survey_summary_api') IS NOT NULL THEN
        RAISE EXCEPTION
            'Precheck failed: reporting.course_faculty_survey_summary_api already exists';
    END IF;
END
$precheck$;

CREATE TEMP TABLE faculty_survey_refresh_context
ON COMMIT DROP
AS
SELECT
    gen_random_uuid() AS run_id,
    CURRENT_TIMESTAMP AS report_as_of_utc;

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
    run_id,
    'course_faculty_survey_summary',
    report_as_of_utc,
    NULL,
    jsonb_build_object(
        'sources',
        jsonb_build_array(
            'component 16 OLD Faculty Course Feedback',
            'component 44 NEW Faculty Course Feedback'
        ),
        'grain',
        'course_id + term_id',
        'response_grain',
        'matched source survey response row',
        'teaching_experience_mapping',
        'OLD Question 1 / NEW Q14',
        'course_quality_mapping',
        'OLD Question 16 / NEW Q15'
    ),
    jsonb_build_object(
        'expected_course_term_rows', 4927,
        'expected_courses', 395,
        'expected_terms', 59,
        'expected_total_responses', 11604,
        'expected_old_responses', 8024,
        'expected_new_responses', 3580,
        'expected_teaching_responses', 11556,
        'expected_teaching_average', 4.6674,
        'expected_quality_responses', 11448,
        'expected_quality_average', 4.4188
    ),
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    'STARTED',
    'Faculty Survey audit-enabled reporting rollback rehearsal.',
    NULL
FROM faculty_survey_refresh_context;

CREATE TABLE reporting.course_faculty_survey_summary AS
WITH faculty_sources AS (
    SELECT
        16 AS component_id,
        'OLD'::text AS survey_version,
        source_row_number,
        NULLIF(BTRIM(c0012), '') AS course_code,

        CASE
            WHEN BTRIM(c0014) ~ '^[^_]+_FCF_'
            THEN REGEXP_REPLACE(
                BTRIM(c0014),
                '^([^_]+)_FCF_',
                E'\\1_'
            )
            ELSE BTRIM(c0014)
        END AS normalized_unique_id,

        NULLIF(BTRIM(c0023), '') AS teaching_experience,
        NULLIF(BTRIM(c0038), '') AS course_quality

    FROM staging.raw_master_facultycour_s01_feots_e4a0bf70

    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0014), '') IS NOT NULL
      AND LOWER(BTRIM(c0014)) <> 'uniqueid'

    UNION ALL

    SELECT
        44,
        'NEW'::text,
        source_row_number,
        NULLIF(BTRIM(c0012), ''),

        CASE
            WHEN BTRIM(c0014) ~ '^[^_]+_FCF_'
            THEN REGEXP_REPLACE(
                BTRIM(c0014),
                '^([^_]+)_FCF_',
                E'\\1_'
            )
            ELSE BTRIM(c0014)
        END,

        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0049), '')

    FROM staging.raw_new_master_faculty_s02_feots_new_18832c28

    WHERE source_row_number IS NOT NULL
      AND NULLIF(BTRIM(c0014), '') IS NOT NULL
      AND LOWER(BTRIM(c0014)) <> 'uniqueid'
),
normalized AS (
    SELECT
        component_id,
        survey_version,
        source_row_number,

        SPLIT_PART(normalized_unique_id, '_', 1)
            AS term_code,

        UPPER(
            REGEXP_REPLACE(
                course_code,
                '[^A-Za-z0-9]',
                '',
                'g'
            )
        )
        || '_'
        || SPLIT_PART(normalized_unique_id, '_', 5)
            AS candidate_source_identifier,

        CASE
            WHEN teaching_experience IN ('1','2','3','4','5')
            THEN teaching_experience::integer
            ELSE NULL
        END AS teaching_experience_rating,

        CASE
            WHEN course_quality IN ('1','2','3','4','5')
            THEN course_quality::integer
            ELSE NULL
        END AS course_quality_rating

    FROM faculty_sources

    WHERE normalized_unique_id IS NOT NULL
      AND course_code IS NOT NULL
),
matched_responses AS (
    SELECT
        n.component_id,
        n.survey_version,
        n.source_row_number,
        n.teaching_experience_rating,
        n.course_quality_rating,
        t.term_id,
        o.course_id

    FROM normalized n

    JOIN core.term t
        ON BTRIM(t.term_code) = n.term_code

    JOIN core.course_offering_section o
        ON o.term_id = t.term_id
       AND UPPER(BTRIM(o.source_identifier))
            = n.candidate_source_identifier
),
aggregated AS (
    SELECT
        course_id,
        term_id,

        MIN(survey_version) AS survey_version,

        COUNT(*)::bigint AS faculty_response_count,

        SUM(
            CASE WHEN survey_version = 'OLD'
            THEN 1 ELSE 0 END
        )::bigint AS old_response_count,

        SUM(
            CASE WHEN survey_version = 'NEW'
            THEN 1 ELSE 0 END
        )::bigint AS new_response_count,

        SUM(
            CASE WHEN teaching_experience_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS teaching_response_count,

        ROUND(
            AVG(teaching_experience_rating),
            4
        ) AS average_teaching_experience,

        SUM(
            CASE WHEN course_quality_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS quality_response_count,

        ROUND(
            AVG(course_quality_rating),
            4
        ) AS average_course_quality

    FROM matched_responses

    GROUP BY
        course_id,
        term_id
)
SELECT
    a.course_id,
    a.term_id,
    t.term_code,
    t.term_label,
    d.university_course_id,
    d.course_code,
    d.course_title,
    d.college_name,
    d.department_name,
    a.survey_version,
    a.faculty_response_count,
    a.old_response_count,
    a.new_response_count,
    a.teaching_response_count,
    a.average_teaching_experience,
    a.quality_response_count,
    a.average_course_quality,

    ctx.run_id AS report_refresh_run_id,
    ctx.report_as_of_utc,

    MD5(
        CONCAT_WS(
            '|',
            a.course_id::text,
            a.term_id::text,
            t.term_code,
            COALESCE(t.term_label, ''),
            d.university_course_id,
            d.course_code,
            d.course_title,
            d.college_name,
            d.department_name,
            a.survey_version,
            a.faculty_response_count::text,
            a.old_response_count::text,
            a.new_response_count::text,
            a.teaching_response_count::text,
            COALESCE(a.average_teaching_experience::text, ''),
            a.quality_response_count::text,
            COALESCE(a.average_course_quality::text, '')
        )
    ) AS business_row_hash

FROM aggregated a

JOIN core.term t
    ON t.term_id = a.term_id

JOIN reporting.course_catalog_detail d
    ON d.course_id = a.course_id

CROSS JOIN faculty_survey_refresh_context ctx;

ALTER TABLE reporting.course_faculty_survey_summary
    ALTER COLUMN course_id SET NOT NULL,
    ALTER COLUMN term_id SET NOT NULL,
    ALTER COLUMN term_code SET NOT NULL,
    ALTER COLUMN course_code SET NOT NULL,
    ALTER COLUMN course_title SET NOT NULL,
    ALTER COLUMN college_name SET NOT NULL,
    ALTER COLUMN department_name SET NOT NULL,
    ALTER COLUMN survey_version SET NOT NULL,
    ALTER COLUMN faculty_response_count SET NOT NULL,
    ALTER COLUMN old_response_count SET NOT NULL,
    ALTER COLUMN new_response_count SET NOT NULL,
    ALTER COLUMN teaching_response_count SET NOT NULL,
    ALTER COLUMN quality_response_count SET NOT NULL,
    ALTER COLUMN report_refresh_run_id SET NOT NULL,
    ALTER COLUMN report_as_of_utc SET NOT NULL,
    ALTER COLUMN business_row_hash SET NOT NULL;

ALTER TABLE reporting.course_faculty_survey_summary
    ADD CONSTRAINT course_faculty_survey_summary_pkey
    PRIMARY KEY (course_id, term_id);

ALTER TABLE reporting.course_faculty_survey_summary
    ADD CONSTRAINT ck_course_faculty_survey_summary_counts
    CHECK (
        faculty_response_count > 0
        AND old_response_count >= 0
        AND new_response_count >= 0
        AND faculty_response_count =
            old_response_count + new_response_count
        AND teaching_response_count >= 0
        AND teaching_response_count <= faculty_response_count
        AND quality_response_count >= 0
        AND quality_response_count <= faculty_response_count
        AND (
            average_teaching_experience IS NULL
            OR average_teaching_experience BETWEEN 1 AND 5
        )
        AND (
            average_course_quality IS NULL
            OR average_course_quality BETWEEN 1 AND 5
        )
        AND survey_version IN ('OLD', 'NEW')
        AND NOT (
            old_response_count > 0
            AND new_response_count > 0
        )
    );

CREATE INDEX course_faculty_survey_summary_course_code_idx
    ON reporting.course_faculty_survey_summary (course_code);

CREATE INDEX course_faculty_survey_summary_term_code_idx
    ON reporting.course_faculty_survey_summary (term_code);

CREATE TABLE reporting.course_faculty_survey_summary_api AS
SELECT
    course_id,
    term_id,
    term_code,
    term_label,
    university_course_id,
    course_code,
    course_title,
    college_name,
    department_name,
    survey_version,
    faculty_response_count,
    old_response_count,
    new_response_count,
    teaching_response_count,
    average_teaching_experience,
    quality_response_count,
    average_course_quality,
    report_refresh_run_id,
    report_as_of_utc,

    MD5(course_id::text || ':' || term_id::text)::uuid
        AS faculty_survey_summary_id

FROM reporting.course_faculty_survey_summary;

ALTER TABLE reporting.course_faculty_survey_summary_api
    ALTER COLUMN faculty_survey_summary_id SET NOT NULL;

ALTER TABLE reporting.course_faculty_survey_summary_api
    ADD CONSTRAINT course_faculty_survey_summary_api_pkey
    PRIMARY KEY (faculty_survey_summary_id);

ALTER TABLE reporting.course_faculty_survey_summary_api
    ADD CONSTRAINT course_faculty_survey_summary_api_course_term_key
    UNIQUE (course_id, term_id);

CREATE INDEX course_faculty_survey_summary_api_course_code_idx
    ON reporting.course_faculty_survey_summary_api (course_code);

CREATE INDEX course_faculty_survey_summary_api_term_code_idx
    ON reporting.course_faculty_survey_summary_api (term_code);

DO $validate$
DECLARE
    v_rows bigint;
    v_courses bigint;
    v_terms bigint;
    v_responses numeric;
    v_old numeric;
    v_new numeric;
    v_teaching numeric;
    v_teaching_avg numeric;
    v_quality numeric;
    v_quality_avg numeric;
    v_mixed bigint;
    v_invalid bigint;
    v_api_rows bigint;
    v_api_ids bigint;
BEGIN
    SELECT
        COUNT(*),
        COUNT(DISTINCT course_id),
        COUNT(DISTINCT term_id),
        SUM(faculty_response_count),
        SUM(old_response_count),
        SUM(new_response_count),
        SUM(teaching_response_count),

        ROUND(
            SUM(
                average_teaching_experience
                * teaching_response_count
            )
            / NULLIF(SUM(teaching_response_count), 0),
            4
        ),

        SUM(quality_response_count),

        ROUND(
            SUM(
                average_course_quality
                * quality_response_count
            )
            / NULLIF(SUM(quality_response_count), 0),
            4
        ),

        SUM(
            CASE
                WHEN old_response_count > 0
                 AND new_response_count > 0
                THEN 1 ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN faculty_response_count <>
                     old_response_count + new_response_count
                THEN 1 ELSE 0
            END
        )

    INTO
        v_rows,
        v_courses,
        v_terms,
        v_responses,
        v_old,
        v_new,
        v_teaching,
        v_teaching_avg,
        v_quality,
        v_quality_avg,
        v_mixed,
        v_invalid

    FROM reporting.course_faculty_survey_summary;

    SELECT
        COUNT(*),
        COUNT(DISTINCT faculty_survey_summary_id)

    INTO
        v_api_rows,
        v_api_ids

    FROM reporting.course_faculty_survey_summary_api;

    IF v_rows <> 4927
       OR v_courses <> 395
       OR v_terms <> 59
       OR v_responses <> 11604
       OR v_old <> 8024
       OR v_new <> 3580
       OR v_teaching <> 11556
       OR v_teaching_avg <> 4.6674
       OR v_quality <> 11448
       OR v_quality_avg <> 4.4188
       OR v_mixed <> 0
       OR v_invalid <> 0
       OR v_api_rows <> 4927
       OR v_api_ids <> 4927
    THEN
        RAISE EXCEPTION
            'Faculty Survey validation failed: rows=%, courses=%, terms=%, responses=%, old=%, new=%, teaching=%, teaching_avg=%, quality=%, quality_avg=%, mixed=%, invalid=%, api_rows=%, api_ids=%',
            v_rows,
            v_courses,
            v_terms,
            v_responses,
            v_old,
            v_new,
            v_teaching,
            v_teaching_avg,
            v_quality,
            v_quality_avg,
            v_mixed,
            v_invalid,
            v_api_rows,
            v_api_ids;
    END IF;
END
$validate$;

UPDATE reporting.projection_refresh_run r
SET
    completed_at = CURRENT_TIMESTAMP,
    source_row_count = 11604,
    rows_inserted = 4927,
    rows_updated = 0,
    rows_deleted = 0,
    rows_unchanged = 0,
    business_checksum = checksum_data.business_checksum,
    status = 'COMPLETED',
    notes = 'Faculty Survey audit-enabled reporting rollback rehearsal completed and reconciled.',
    error_information = NULL

FROM faculty_survey_refresh_context ctx

CROSS JOIN LATERAL (
    SELECT
        MD5(
            STRING_AGG(
                s.business_row_hash,
                ''
                ORDER BY s.course_id, s.term_id
            )
        ) AS business_checksum

    FROM reporting.course_faculty_survey_summary s
) checksum_data

WHERE r.run_id = ctx.run_id;

SELECT
    COUNT(*) AS summary_rows,
    COUNT(DISTINCT course_id) AS represented_courses,
    COUNT(DISTINCT term_id) AS represented_terms,
    SUM(faculty_response_count) AS total_faculty_responses,
    SUM(old_response_count) AS old_response_count,
    SUM(new_response_count) AS new_response_count,
    SUM(teaching_response_count) AS teaching_response_count,

    ROUND(
        SUM(
            average_teaching_experience
            * teaching_response_count
        )
        / NULLIF(SUM(teaching_response_count), 0),
        4
    ) AS weighted_average_teaching_experience,

    SUM(quality_response_count) AS quality_response_count,

    ROUND(
        SUM(
            average_course_quality
            * quality_response_count
        )
        / NULLIF(SUM(quality_response_count), 0),
        4
    ) AS weighted_average_course_quality

FROM reporting.course_faculty_survey_summary;

SELECT
    run_id,
    projection_name,
    source_row_count,
    rows_inserted,
    rows_updated,
    rows_deleted,
    rows_unchanged,
    business_checksum,
    status

FROM reporting.projection_refresh_run

WHERE run_id = (
    SELECT run_id
    FROM faculty_survey_refresh_context
);

SELECT
    COUNT(*) AS tables_visible_inside_transaction

FROM information_schema.tables

WHERE table_schema = 'reporting'
  AND table_name IN (
      'course_faculty_survey_summary',
      'course_faculty_survey_summary_api'
  );

ROLLBACK;

SELECT
    COUNT(*) AS tables_after_rollback

FROM information_schema.tables

WHERE table_schema = 'reporting'
  AND table_name IN (
      'course_faculty_survey_summary',
      'course_faculty_survey_summary_api'
  );

SELECT
    COUNT(*) AS refresh_runs_after_rollback

FROM reporting.projection_refresh_run

WHERE projection_name = 'course_faculty_survey_summary';
