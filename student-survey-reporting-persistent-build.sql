\set ON_ERROR_STOP on

BEGIN;

DO $precheck$
BEGIN
    IF to_regclass(
        'reporting.course_student_survey_summary'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            'Precheck failed: reporting.course_student_survey_summary already exists';
    END IF;

    IF to_regclass(
        'reporting.course_student_survey_summary_api'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            'Precheck failed: reporting.course_student_survey_summary_api already exists';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM reporting.projection_refresh_run
        WHERE projection_name =
            'course_student_survey_summary'
    ) THEN
        RAISE EXCEPTION
            'Precheck failed: Student Survey refresh record already exists';
    END IF;
END
$precheck$;

CREATE TEMP TABLE student_survey_refresh_context
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
    'course_student_survey_summary',
    report_as_of_utc,
    NULL,

    jsonb_build_object(
        'grain',
        'course_id + term_id',

        'response_grain',
        'deduplicated response_id matched to governed offering',

        'new_source_rule',
        'component 35 NEW_SPOTS plus component 34 NEW_RAW-only responses',

        'old_source_rule',
        'components 37, 40, 41, and 42',

        'source_priority',
        jsonb_build_array(
            '35 NEW_SPOTS',
            '34 NEW_RAW',
            '37 OLD_P1',
            '40 OLD_P2',
            '41 OLD_P3',
            '42 OLD_P4'
        ),

        'teaching_effectiveness_mapping',
        'OLD Question 26 / NEW Question 7',

        'old_course_quality_mapping',
        'OLD Question 28',

        'new_course_recommendation_mapping',
        'NEW Question 13',

        'rating_scale',
        '1-5'
    ),

    jsonb_build_object(
        'expected_course_term_rows', 5809,
        'expected_courses', 404,
        'expected_terms', 59,
        'expected_total_responses', 181375,
        'expected_old_responses', 146748,
        'expected_new_responses', 34627,
        'expected_teaching_responses', 93525,
        'expected_teaching_average', 4.5518,
        'expected_course_quality_responses', 69346,
        'expected_course_quality_average', 4.4858,
        'expected_course_recommendation_responses', 19801,
        'expected_course_recommendation_average', 4.5674,
        'expected_mixed_version_rows', 0
    ),

    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    'STARTED',
    'Initial controlled Student Survey reporting projection build.',
    NULL

FROM student_survey_refresh_context;

CREATE TABLE reporting.course_student_survey_summary AS
WITH all_source_rows AS (
    SELECT
        1 AS source_priority,
        35 AS component_id,
        'NEW'::text AS survey_version,
        source_row_number,
        NULLIF(BTRIM(c0001), '') AS response_id,
        NULLIF(BTRIM(c0012), '') AS course_code,
        NULLIF(BTRIM(c0014), '') AS unique_id,
        NULLIF(BTRIM(c0029), '') AS teaching_effectiveness,
        NULLIF(BTRIM(c0035), '') AS version_specific_rating
    FROM staging.raw_master_online_new_s02_spots_3caa2498

    UNION ALL

    SELECT
        2,
        34,
        'NEW'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0029), ''),
        NULLIF(BTRIM(c0035), '')
    FROM staging.raw_master_online_new_s01_rawdata_3caa2498

    UNION ALL

    SELECT
        3,
        37,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_31fb6e24

    UNION ALL

    SELECT
        4,
        40,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_3417e822

    UNION ALL

    SELECT
        5,
        41,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_324dd997

    UNION ALL

    SELECT
        6,
        42,
        'OLD'::text,
        source_row_number,
        NULLIF(BTRIM(c0001), ''),
        NULLIF(BTRIM(c0012), ''),
        NULLIF(BTRIM(c0014), ''),
        NULLIF(BTRIM(c0048), ''),
        NULLIF(BTRIM(c0050), '')
    FROM staging.raw_master_online_part_s01_online_6164ddea
),

valid_source_rows AS (
    SELECT *
    FROM all_source_rows
    WHERE response_id IS NOT NULL
      AND course_code IS NOT NULL
      AND unique_id IS NOT NULL
      AND LOWER(BTRIM(response_id)) NOT IN (
          'responseuniqueid',
          'response unique id',
          'response_id',
          'responseid'
      )
      AND LOWER(BTRIM(unique_id)) <> 'uniqueid'
),

deduplicated_responses AS (
    SELECT
        component_id,
        survey_version,
        source_row_number,
        response_id,
        course_code,
        unique_id,
        teaching_effectiveness,
        version_specific_rating
    FROM (
        SELECT
            v.*,
            ROW_NUMBER() OVER (
                PARTITION BY response_id
                ORDER BY
                    source_priority,
                    component_id,
                    source_row_number
            ) AS response_rank
        FROM valid_source_rows v
    ) ranked
    WHERE response_rank = 1
),

normalized AS (
    SELECT
        component_id,
        survey_version,
        source_row_number,
        response_id,

        SPLIT_PART(unique_id, '_', 1) AS term_code,

        UPPER(
            REGEXP_REPLACE(
                course_code,
                '[^A-Za-z0-9]',
                '',
                'g'
            )
        )
        || '_'
        || SPLIT_PART(unique_id, '_', 5)
            AS candidate_source_identifier,

        CASE
            WHEN teaching_effectiveness IN ('1','2','3','4','5')
            THEN teaching_effectiveness::integer
            ELSE NULL
        END AS teaching_effectiveness_rating,

        CASE
            WHEN version_specific_rating IN ('1','2','3','4','5')
            THEN version_specific_rating::integer
            ELSE NULL
        END AS version_specific_rating

    FROM deduplicated_responses
),

matched_responses AS (
    SELECT
        n.component_id,
        n.survey_version,
        n.source_row_number,
        n.response_id,
        n.teaching_effectiveness_rating,

        CASE
            WHEN n.survey_version = 'OLD'
            THEN n.version_specific_rating
            ELSE NULL
        END AS course_quality_rating,

        CASE
            WHEN n.survey_version = 'NEW'
            THEN n.version_specific_rating
            ELSE NULL
        END AS course_recommendation_rating,

        t.term_id,
        o.course_id,
        o.course_offering_id

    FROM normalized n

    JOIN core.term t
        ON BTRIM(t.term_code) = n.term_code

    JOIN core.course_offering_section o
        ON o.term_id = t.term_id
       AND UPPER(BTRIM(o.source_identifier))
            = n.candidate_source_identifier
),

course_term_summary AS (
    SELECT
        course_id,
        term_id,

        COUNT(*)::bigint AS student_response_count,

        SUM(
            CASE WHEN survey_version = 'OLD'
            THEN 1 ELSE 0 END
        )::bigint AS old_response_count,

        SUM(
            CASE WHEN survey_version = 'NEW'
            THEN 1 ELSE 0 END
        )::bigint AS new_response_count,

        SUM(
            CASE WHEN teaching_effectiveness_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS teaching_response_count,

        ROUND(
            AVG(teaching_effectiveness_rating),
            4
        ) AS average_teaching_effectiveness,

        SUM(
            CASE WHEN course_quality_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS course_quality_response_count,

        ROUND(
            AVG(course_quality_rating),
            4
        ) AS average_course_quality,

        SUM(
            CASE WHEN course_recommendation_rating IS NOT NULL
            THEN 1 ELSE 0 END
        )::bigint AS course_recommendation_response_count,

        ROUND(
            AVG(course_recommendation_rating),
            4
        ) AS average_course_recommendation

    FROM matched_responses

    GROUP BY
        course_id,
        term_id
)
SELECT
    s.course_id,
    s.term_id,
    t.term_code,
    t.term_label,
    d.university_course_id,
    d.course_code,
    d.course_title,
    d.college_name,
    d.department_name,

    CASE
        WHEN s.old_response_count > 0
        THEN 'OLD'
        WHEN s.new_response_count > 0
        THEN 'NEW'
        ELSE NULL
    END AS survey_version,

    s.student_response_count,
    s.old_response_count,
    s.new_response_count,

    s.teaching_response_count,
    s.average_teaching_effectiveness,

    s.course_quality_response_count,
    s.average_course_quality,

    s.course_recommendation_response_count,
    s.average_course_recommendation,

    ctx.run_id AS report_refresh_run_id,
    ctx.report_as_of_utc,

    MD5(
        CONCAT_WS(
            '|',
            s.course_id::text,
            s.term_id::text,
            t.term_code,
            COALESCE(t.term_label, ''),
            d.university_course_id,
            d.course_code,
            d.course_title,
            d.college_name,
            d.department_name,

            CASE
                WHEN s.old_response_count > 0
                THEN 'OLD'
                WHEN s.new_response_count > 0
                THEN 'NEW'
                ELSE ''
            END,

            s.student_response_count::text,
            s.old_response_count::text,
            s.new_response_count::text,

            s.teaching_response_count::text,
            COALESCE(
                s.average_teaching_effectiveness::text,
                ''
            ),

            s.course_quality_response_count::text,
            COALESCE(
                s.average_course_quality::text,
                ''
            ),

            s.course_recommendation_response_count::text,
            COALESCE(
                s.average_course_recommendation::text,
                ''
            )
        )
    ) AS business_row_hash

FROM course_term_summary s

JOIN core.term t
    ON t.term_id = s.term_id

JOIN reporting.course_catalog_detail d
    ON d.course_id = s.course_id

CROSS JOIN student_survey_refresh_context ctx;

ALTER TABLE reporting.course_student_survey_summary
    ALTER COLUMN course_id SET NOT NULL,
    ALTER COLUMN term_id SET NOT NULL,
    ALTER COLUMN term_code SET NOT NULL,
    ALTER COLUMN course_code SET NOT NULL,
    ALTER COLUMN course_title SET NOT NULL,
    ALTER COLUMN college_name SET NOT NULL,
    ALTER COLUMN department_name SET NOT NULL,
    ALTER COLUMN survey_version SET NOT NULL,
    ALTER COLUMN student_response_count SET NOT NULL,
    ALTER COLUMN old_response_count SET NOT NULL,
    ALTER COLUMN new_response_count SET NOT NULL,
    ALTER COLUMN teaching_response_count SET NOT NULL,
    ALTER COLUMN course_quality_response_count SET NOT NULL,
    ALTER COLUMN course_recommendation_response_count SET NOT NULL,
    ALTER COLUMN report_refresh_run_id SET NOT NULL,
    ALTER COLUMN report_as_of_utc SET NOT NULL,
    ALTER COLUMN business_row_hash SET NOT NULL;

ALTER TABLE reporting.course_student_survey_summary
    ADD CONSTRAINT course_student_survey_summary_pkey
    PRIMARY KEY (course_id, term_id);

ALTER TABLE reporting.course_student_survey_summary
    ADD CONSTRAINT ck_course_student_survey_summary_counts
    CHECK (
        student_response_count > 0

        AND old_response_count >= 0
        AND new_response_count >= 0

        AND student_response_count =
            old_response_count + new_response_count

        AND teaching_response_count >= 0
        AND teaching_response_count <= student_response_count

        AND course_quality_response_count >= 0
        AND course_quality_response_count <= student_response_count

        AND course_recommendation_response_count >= 0
        AND course_recommendation_response_count
            <= student_response_count

        AND (
            average_teaching_effectiveness IS NULL
            OR average_teaching_effectiveness BETWEEN 1 AND 5
        )

        AND (
            average_course_quality IS NULL
            OR average_course_quality BETWEEN 1 AND 5
        )

        AND (
            average_course_recommendation IS NULL
            OR average_course_recommendation BETWEEN 1 AND 5
        )

        AND survey_version IN ('OLD', 'NEW')

        AND NOT (
            old_response_count > 0
            AND new_response_count > 0
        )

        AND (
            survey_version <> 'OLD'
            OR course_recommendation_response_count = 0
        )

        AND (
            survey_version <> 'NEW'
            OR course_quality_response_count = 0
        )
    );

CREATE INDEX course_student_survey_summary_course_code_idx
    ON reporting.course_student_survey_summary (
        course_code
    );

CREATE INDEX course_student_survey_summary_term_code_idx
    ON reporting.course_student_survey_summary (
        term_code
    );

CREATE TABLE reporting.course_student_survey_summary_api AS
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

    student_response_count,
    old_response_count,
    new_response_count,

    teaching_response_count,
    average_teaching_effectiveness,

    course_quality_response_count,
    average_course_quality,

    course_recommendation_response_count,
    average_course_recommendation,

    report_refresh_run_id,
    report_as_of_utc,

    MD5(
        course_id::text || ':' || term_id::text
    )::uuid AS student_survey_summary_id

FROM reporting.course_student_survey_summary;

ALTER TABLE reporting.course_student_survey_summary_api
    ALTER COLUMN student_survey_summary_id SET NOT NULL;

ALTER TABLE reporting.course_student_survey_summary_api
    ADD CONSTRAINT course_student_survey_summary_api_pkey
    PRIMARY KEY (student_survey_summary_id);

ALTER TABLE reporting.course_student_survey_summary_api
    ADD CONSTRAINT course_student_survey_summary_api_course_term_key
    UNIQUE (course_id, term_id);

CREATE INDEX course_student_survey_summary_api_course_code_idx
    ON reporting.course_student_survey_summary_api (
        course_code
    );

CREATE INDEX course_student_survey_summary_api_term_code_idx
    ON reporting.course_student_survey_summary_api (
        term_code
    );

DO $validate$
DECLARE
    v_rows bigint;
    v_courses bigint;
    v_terms bigint;

    v_total_responses numeric;
    v_old_responses numeric;
    v_new_responses numeric;

    v_teaching_responses numeric;
    v_teaching_average numeric;

    v_quality_responses numeric;
    v_quality_average numeric;

    v_recommendation_responses numeric;
    v_recommendation_average numeric;

    v_mixed_versions bigint;
    v_invalid_counts bigint;
    v_invalid_ratings bigint;
    v_invalid_version_metrics bigint;

    v_api_rows bigint;
    v_api_ids bigint;
    v_business_keys bigint;

    v_asci_rows bigint;
    v_asci_responses numeric;
    v_asci_teaching_responses numeric;
    v_asci_teaching_average numeric;
    v_asci_quality_responses numeric;
    v_asci_recommendation_responses numeric;
    v_asci_recommendation_average numeric;
BEGIN
    SELECT
        COUNT(*),
        COUNT(DISTINCT course_id),
        COUNT(DISTINCT term_id),

        SUM(student_response_count),
        SUM(old_response_count),
        SUM(new_response_count),

        SUM(teaching_response_count),

        ROUND(
            SUM(
                average_teaching_effectiveness
                * teaching_response_count
            )
            / NULLIF(
                SUM(teaching_response_count),
                0
            ),
            4
        ),

        SUM(course_quality_response_count),

        ROUND(
            SUM(
                average_course_quality
                * course_quality_response_count
            )
            / NULLIF(
                SUM(course_quality_response_count),
                0
            ),
            4
        ),

        SUM(course_recommendation_response_count),

        ROUND(
            SUM(
                average_course_recommendation
                * course_recommendation_response_count
            )
            / NULLIF(
                SUM(course_recommendation_response_count),
                0
            ),
            4
        ),

        SUM(
            CASE
                WHEN old_response_count > 0
                 AND new_response_count > 0
                THEN 1
                ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN student_response_count <>
                    old_response_count + new_response_count
                  OR teaching_response_count < 0
                  OR teaching_response_count >
                    student_response_count
                  OR course_quality_response_count < 0
                  OR course_quality_response_count >
                    student_response_count
                  OR course_recommendation_response_count < 0
                  OR course_recommendation_response_count >
                    student_response_count
                THEN 1
                ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN (
                    average_teaching_effectiveness IS NOT NULL
                    AND average_teaching_effectiveness
                        NOT BETWEEN 1 AND 5
                )
                OR (
                    average_course_quality IS NOT NULL
                    AND average_course_quality
                        NOT BETWEEN 1 AND 5
                )
                OR (
                    average_course_recommendation IS NOT NULL
                    AND average_course_recommendation
                        NOT BETWEEN 1 AND 5
                )
                THEN 1
                ELSE 0
            END
        ),

        SUM(
            CASE
                WHEN survey_version = 'OLD'
                 AND course_recommendation_response_count <> 0
                THEN 1

                WHEN survey_version = 'NEW'
                 AND course_quality_response_count <> 0
                THEN 1

                ELSE 0
            END
        )

    INTO
        v_rows,
        v_courses,
        v_terms,

        v_total_responses,
        v_old_responses,
        v_new_responses,

        v_teaching_responses,
        v_teaching_average,

        v_quality_responses,
        v_quality_average,

        v_recommendation_responses,
        v_recommendation_average,

        v_mixed_versions,
        v_invalid_counts,
        v_invalid_ratings,
        v_invalid_version_metrics

    FROM reporting.course_student_survey_summary;

    SELECT
        COUNT(*),
        COUNT(DISTINCT student_survey_summary_id),
        COUNT(
            DISTINCT course_id::text || ':' || term_id::text
        )

    INTO
        v_api_rows,
        v_api_ids,
        v_business_keys

    FROM reporting.course_student_survey_summary_api;

    SELECT
        COUNT(*),
        SUM(student_response_count),
        SUM(teaching_response_count),
        MAX(average_teaching_effectiveness),
        SUM(course_quality_response_count),
        SUM(course_recommendation_response_count),
        MAX(average_course_recommendation)

    INTO
        v_asci_rows,
        v_asci_responses,
        v_asci_teaching_responses,
        v_asci_teaching_average,
        v_asci_quality_responses,
        v_asci_recommendation_responses,
        v_asci_recommendation_average

    FROM reporting.course_student_survey_summary

    WHERE course_id =
        '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid
      AND term_code = '2967';

    IF v_rows <> 5809
       OR v_courses <> 404
       OR v_terms <> 59

       OR v_total_responses <> 181375
       OR v_old_responses <> 146748
       OR v_new_responses <> 34627

       OR v_teaching_responses <> 93525
       OR v_teaching_average <> 4.5518

       OR v_quality_responses <> 69346
       OR v_quality_average <> 4.4858

       OR v_recommendation_responses <> 19801
       OR v_recommendation_average <> 4.5674

       OR v_mixed_versions <> 0
       OR v_invalid_counts <> 0
       OR v_invalid_ratings <> 0
       OR v_invalid_version_metrics <> 0

       OR v_api_rows <> 5809
       OR v_api_ids <> 5809
       OR v_business_keys <> 5809

       OR v_asci_rows <> 1
       OR v_asci_responses <> 88
       OR v_asci_teaching_responses <> 86
       OR v_asci_teaching_average <> 4.8140
       OR v_asci_quality_responses <> 0
       OR v_asci_recommendation_responses <> 85
       OR v_asci_recommendation_average <> 4.7412
    THEN
        RAISE EXCEPTION
            'Student Survey validation failed: rows=%, courses=%, terms=%, responses=%, old=%, new=%, teaching=%, teaching_avg=%, quality=%, quality_avg=%, recommendation=%, recommendation_avg=%, mixed=%, invalid_counts=%, invalid_ratings=%, invalid_version_metrics=%, api_rows=%, api_ids=%, business_keys=%, ASCI_rows=%, ASCI_responses=%, ASCI_teaching=%, ASCI_teaching_avg=%, ASCI_quality=%, ASCI_recommendation=%, ASCI_recommendation_avg=%',
            v_rows,
            v_courses,
            v_terms,
            v_total_responses,
            v_old_responses,
            v_new_responses,
            v_teaching_responses,
            v_teaching_average,
            v_quality_responses,
            v_quality_average,
            v_recommendation_responses,
            v_recommendation_average,
            v_mixed_versions,
            v_invalid_counts,
            v_invalid_ratings,
            v_invalid_version_metrics,
            v_api_rows,
            v_api_ids,
            v_business_keys,
            v_asci_rows,
            v_asci_responses,
            v_asci_teaching_responses,
            v_asci_teaching_average,
            v_asci_quality_responses,
            v_asci_recommendation_responses,
            v_asci_recommendation_average;
    END IF;
END
$validate$;

UPDATE reporting.projection_refresh_run r

SET
    completed_at = CURRENT_TIMESTAMP,
    source_row_count = 181375,
    rows_inserted = 5809,
    rows_updated = 0,
    rows_deleted = 0,
    rows_unchanged = 0,
    business_checksum =
        checksum_data.business_checksum,
    status = 'COMPLETED',
    notes =
        'Initial Student Survey reporting projection completed and reconciled.',
    error_information = NULL

FROM student_survey_refresh_context ctx

CROSS JOIN LATERAL (
    SELECT
        MD5(
            STRING_AGG(
                s.business_row_hash,
                ''
                ORDER BY
                    s.course_id,
                    s.term_id
            )
        ) AS business_checksum

    FROM reporting.course_student_survey_summary s
) checksum_data

WHERE r.run_id = ctx.run_id;

SELECT
    COUNT(*) AS summary_rows,
    COUNT(DISTINCT course_id)
        AS represented_courses,
    COUNT(DISTINCT term_id)
        AS represented_terms,

    SUM(student_response_count)
        AS total_student_responses,

    SUM(old_response_count)
        AS old_response_count,

    SUM(new_response_count)
        AS new_response_count,

    SUM(teaching_response_count)
        AS teaching_response_count,

    ROUND(
        SUM(
            average_teaching_effectiveness
            * teaching_response_count
        )
        / NULLIF(
            SUM(teaching_response_count),
            0
        ),
        4
    ) AS weighted_average_teaching_effectiveness,

    SUM(course_quality_response_count)
        AS course_quality_response_count,

    ROUND(
        SUM(
            average_course_quality
            * course_quality_response_count
        )
        / NULLIF(
            SUM(course_quality_response_count),
            0
        ),
        4
    ) AS weighted_average_course_quality,

    SUM(course_recommendation_response_count)
        AS course_recommendation_response_count,

    ROUND(
        SUM(
            average_course_recommendation
            * course_recommendation_response_count
        )
        / NULLIF(
            SUM(course_recommendation_response_count),
            0
        ),
        4
    ) AS weighted_average_course_recommendation

FROM reporting.course_student_survey_summary;

SELECT
    COUNT(*) AS api_rows,

    COUNT(
        DISTINCT student_survey_summary_id
    ) AS unique_api_ids,

    COUNT(
        DISTINCT course_id::text || ':' || term_id::text
    ) AS unique_business_keys

FROM reporting.course_student_survey_summary_api;

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
    FROM student_survey_refresh_context
);

SELECT
    term_code,
    term_label,
    survey_version,
    student_response_count,
    teaching_response_count,
    average_teaching_effectiveness,
    course_quality_response_count,
    average_course_quality,
    course_recommendation_response_count,
    average_course_recommendation

FROM reporting.course_student_survey_summary

WHERE course_id =
    '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid

ORDER BY
    CASE
        WHEN term_code ~ '^[0-9]+$'
        THEN term_code::integer
        ELSE NULL
    END DESC,
    term_code DESC

LIMIT 5;

SELECT
    COUNT(*) AS tables_visible_inside_transaction

FROM information_schema.tables

WHERE table_schema = 'reporting'
  AND table_name IN (
      'course_student_survey_summary',
      'course_student_survey_summary_api'
  );

COMMIT;

SELECT
    COUNT(*) AS summary_rows,
    COUNT(DISTINCT course_id) AS represented_courses,
    COUNT(DISTINCT term_id) AS represented_terms,

    SUM(student_response_count) AS total_student_responses,
    SUM(old_response_count) AS old_response_count,
    SUM(new_response_count) AS new_response_count,

    SUM(teaching_response_count) AS teaching_response_count,

    ROUND(
        SUM(
            average_teaching_effectiveness
            * teaching_response_count
        )
        / NULLIF(SUM(teaching_response_count), 0),
        4
    ) AS weighted_average_teaching_effectiveness,

    SUM(course_quality_response_count)
        AS course_quality_response_count,

    ROUND(
        SUM(
            average_course_quality
            * course_quality_response_count
        )
        / NULLIF(SUM(course_quality_response_count), 0),
        4
    ) AS weighted_average_course_quality,

    SUM(course_recommendation_response_count)
        AS course_recommendation_response_count,

    ROUND(
        SUM(
            average_course_recommendation
            * course_recommendation_response_count
        )
        / NULLIF(
            SUM(course_recommendation_response_count),
            0
        ),
        4
    ) AS weighted_average_course_recommendation

FROM reporting.course_student_survey_summary;


SELECT
    COUNT(*) AS api_rows,
    COUNT(DISTINCT student_survey_summary_id)
        AS unique_api_ids,
    COUNT(
        DISTINCT course_id::text || ':' || term_id::text
    ) AS unique_business_keys

FROM reporting.course_student_survey_summary_api;


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

WHERE projection_name =
    'course_student_survey_summary'

ORDER BY started_at DESC

LIMIT 1;


SELECT
    term_code,
    term_label,
    survey_version,
    student_response_count,
    teaching_response_count,
    average_teaching_effectiveness,
    course_quality_response_count,
    average_course_quality,
    course_recommendation_response_count,
    average_course_recommendation

FROM reporting.course_student_survey_summary

WHERE course_id =
    '249d04a1-7b12-4fb7-a62c-a5d21cad42dd'::uuid

ORDER BY
    CASE
        WHEN term_code ~ '^[0-9]+$'
        THEN term_code::integer
        ELSE NULL
    END DESC,
    term_code DESC

LIMIT 5;