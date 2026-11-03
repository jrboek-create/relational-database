-- One-time: gives an existing Directus user the Admin role in this app. Replace __EMAIL__ with that user's email
-- (the PowerShell command in the README does this). Stops without changes if the email is not a Directus user.
BEGIN;
DO $$
DECLARE u record;
BEGIN
    SELECT id, email, coalesce(nullif(btrim(concat_ws(' ', first_name, last_name)), ''), email) AS name INTO u
    FROM directus_users WHERE lower(email) = lower('__EMAIL__');
    IF u.id IS NULL THEN
        RAISE EXCEPTION 'No Directus user with email %; nothing was changed', '__EMAIL__';
    END IF;
    INSERT INTO public.app_user (directus_user_id, email, display_name, role_id)
    VALUES (u.id, u.email, u.name, (SELECT id FROM public.app_role WHERE is_admin))
    ON CONFLICT (directus_user_id) DO UPDATE SET role_id = EXCLUDED.role_id, active = true;
    RAISE NOTICE 'App Admin: % (%)', u.name, u.email;
END $$;
SELECT u.email, u.display_name, r.name AS role, u.active FROM public.app_user u JOIN public.app_role r ON r.id = u.role_id;
COMMIT;
