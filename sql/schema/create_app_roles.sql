-- One-time setup (stage 1 of roles and permissions, 3 Nov 2026).
-- app_role: roles. Admin (is_admin) sees everything and cannot be edited or deleted.
-- app_role_permission: the ticked items of each role (keys defined in middleware/src/permissions.js).
-- app_user: which Directus user has which role in this app (passwords stay in Directus).
-- Tables live in the public schema so Directus can serve them. The middleware's read-only token may read them;
-- changes are made later through the Admin page with a separate admin token.
BEGIN;
CREATE TABLE public.app_role (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
    is_admin boolean NOT NULL DEFAULT false,
    built_in boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.app_role_permission (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role_id uuid NOT NULL REFERENCES public.app_role(id) ON DELETE CASCADE,
    permission_key text NOT NULL CHECK (permission_key ~ '^[a-z_]+(\.[a-z0-9_]+)*$'),
    UNIQUE (role_id, permission_key)
);
CREATE TABLE public.app_user (
    directus_user_id uuid PRIMARY KEY,
    email text NOT NULL UNIQUE,
    display_name text NOT NULL,
    role_id uuid NOT NULL REFERENCES public.app_role(id),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);
-- Only one Admin role, and it can never be removed by mistake
CREATE UNIQUE INDEX app_role_one_admin ON public.app_role (is_admin) WHERE is_admin;
INSERT INTO public.app_role (name, is_admin, built_in) VALUES ('Admin', true, true);
INSERT INTO public.app_role (name) VALUES ('ID Level 1'), ('ID Level 2'), ('ID Level 3'), ('ID Director');   -- start with only the 'all users' items
GRANT SELECT, INSERT, UPDATE, DELETE ON public.app_role, public.app_role_permission, public.app_user TO directus_runtime;

-- Directus: register the three collections like the reporting ones, readable by the middleware's token policy
INSERT INTO directus_collections
SELECT (jsonb_populate_record(NULL::directus_collections,
        to_jsonb(c) || jsonb_build_object('collection', x.name, 'note', x.note, 'display_template', NULL, 'hidden', true))).*
FROM directus_collections c
CROSS JOIN (VALUES ('app_role', 'App roles (roles and permissions).'),
                   ('app_role_permission', 'App role permissions: ticked items per role.'),
                   ('app_user', 'App users: Directus user to app role.')) AS x(name, note)
WHERE c.collection = 'course_dfwi_summary_api'
  AND NOT EXISTS (SELECT 1 FROM directus_collections d WHERE d.collection = x.name);
INSERT INTO directus_permissions (collection, action, fields, policy, permissions, validation, presets)
SELECT x.name, p.action, p.fields, p.policy, p.permissions, p.validation, p.presets
FROM directus_permissions p
CROSS JOIN (VALUES ('app_role'), ('app_role_permission'), ('app_user')) AS x(name)
WHERE p.collection = 'course_dfwi_summary_api' AND p.action = 'read'
  AND NOT EXISTS (SELECT 1 FROM directus_permissions d WHERE d.collection = x.name AND d.action = 'read');
SELECT name, is_admin, built_in FROM public.app_role ORDER BY is_admin DESC, name;
SELECT collection, action, fields FROM directus_permissions WHERE collection LIKE 'app\_%' ORDER BY 1;
COMMIT;
