-- One-time: registers reporting.course_redeveloped_summary_api in Directus by copying the settings and the read
-- permission of the existing DFWI API collection (same policy, fields '*'). Safe to run twice. Restart Directus afterwards.
BEGIN;
INSERT INTO directus_collections
SELECT (jsonb_populate_record(NULL::directus_collections,
        to_jsonb(c) || jsonb_build_object('collection', 'course_redeveloped_summary_api',
                                          'note', 'Controlled read-only redeveloped course feedback API reporting projection.',
                                          'display_template', NULL))).*
FROM directus_collections c
WHERE c.collection = 'course_dfwi_summary_api'
  AND NOT EXISTS (SELECT 1 FROM directus_collections WHERE collection = 'course_redeveloped_summary_api');

INSERT INTO directus_permissions (collection, action, fields, policy, permissions, validation, presets)
SELECT 'course_redeveloped_summary_api', p.action, p.fields, p.policy, p.permissions, p.validation, p.presets
FROM directus_permissions p
WHERE p.collection = 'course_dfwi_summary_api' AND p.action = 'read'
  AND NOT EXISTS (SELECT 1 FROM directus_permissions WHERE collection = 'course_redeveloped_summary_api' AND action = 'read');

SELECT c.collection, c.note, p.action, p.fields, p.policy
FROM directus_collections c JOIN directus_permissions p USING (collection)
WHERE c.collection IN ('course_dfwi_summary_api', 'course_redeveloped_summary_api') ORDER BY 1;
COMMIT;
