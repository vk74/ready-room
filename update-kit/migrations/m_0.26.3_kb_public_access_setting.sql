-- Version: 0.26.3
-- Description: Seed KnowledgeBase.allow.public.access setting (default false, public) for the KB module public access safety gate.
-- Backend file: m_0.26.3_kb_public_access_setting.sql
--
-- Changes in v0.26.3:
-- - Seed KnowledgeBase.allow.public.access in app.app_settings without overwriting existing administrator value.

BEGIN;

INSERT INTO app.app_settings (
    section_path, setting_name, environment, value, validation_schema, default_value, description, is_public
) VALUES (
    'KnowledgeBase',
    'allow.public.access',
    'all',
    'false'::jsonb,
    '{"type":"boolean"}'::jsonb,
    'false'::jsonb,
    'When true the public (no login required) access level can be enabled on KB trees. Turning this off downgrades any public KB trees to all registered users.',
    true
)
ON CONFLICT (section_path, setting_name, environment) DO UPDATE SET
    validation_schema = EXCLUDED.validation_schema,
    default_value = EXCLUDED.default_value,
    description = EXCLUDED.description,
    is_public = EXCLUDED.is_public;

DO $$
BEGIN
    PERFORM app.set_migration_output_summary(
        'm_0.26.3',
        'Seeds KnowledgeBase.allow.public.access (default false, public) for the KB module public access safety gate.'
    );
END $$;

UPDATE app.instance
SET schema_version = '0.26.3', last_updated_at = NOW()
WHERE id = 1;

COMMIT;
