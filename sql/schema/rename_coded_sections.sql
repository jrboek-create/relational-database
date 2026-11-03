-- One-time (3 Nov 2026): stores grade section names that carry a middle code (ENGL222_OL_0006, ENGL222_EV_2751)
-- under the plain name (ENGL222_0006), matching the uploader's rule. Expected: 29 grade rows, 2 sections, no sections table rows.
-- Stops without changing anything if a plain name already exists in the same term or the count is not as expected.
BEGIN;
DO $$
DECLARE collisions integer; renamed integer;
BEGIN
    SELECT count(*) INTO collisions
    FROM (SELECT DISTINCT term_id, split_part(course_section_text, '_', 1) || '_' || split_part(course_section_text, '_', 3) AS plain_name
          FROM core.grade WHERE course_section_text ~ '^[^_]+_[A-Za-z]+_[^_]+$') c
    WHERE EXISTS (SELECT 1 FROM core.grade g WHERE g.term_id = c.term_id AND g.course_section_text = c.plain_name)
       OR EXISTS (SELECT 1 FROM core.course_offering_section o WHERE o.term_id = c.term_id AND o.source_section_identifier = c.plain_name);
    IF collisions > 0 THEN
        RAISE EXCEPTION 'Stopped: % plain section name(s) already exist in the same term; nothing was changed', collisions;
    END IF;
    UPDATE core.grade
       SET course_section_text = split_part(course_section_text, '_', 1) || '_' || split_part(course_section_text, '_', 3)
     WHERE course_section_text ~ '^[^_]+_[A-Za-z]+_[^_]+$';
    GET DIAGNOSTICS renamed = ROW_COUNT;
    IF renamed <> 29 THEN
        RAISE EXCEPTION 'Stopped: expected 29 grade rows, found %; nothing was changed', renamed;
    END IF;
    RAISE NOTICE 'Renamed % grade rows', renamed;
END $$;
SELECT t.term_code, g.course_section_text, count(*) AS grade_rows
FROM core.grade g JOIN core.term t ON t.term_id = g.term_id
WHERE g.course_section_text IN ('ENGL222_0006', 'ENGL222_2751') AND t.term_code = '2943'
GROUP BY 1, 2 ORDER BY 2;
COMMIT;
