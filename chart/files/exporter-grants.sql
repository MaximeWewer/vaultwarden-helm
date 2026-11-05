-- Grants of the vaultwarden-exporter read-only role, run by the chart Job as the
-- owner of the Vaultwarden tables (CNPG <cluster>-app). The role itself is
-- created by CNPG (cnpg.yaml: spec.managed.roles). Same grants as
-- https://github.com/MaximeWewer/vaultwarden-exporter/blob/main/deployments/sql/postgresql-readonly.sql
-- Column-level only: never password hashes, keys or vault data.
\set ON_ERROR_STOP 1
DO $$
BEGIN
  IF to_regclass('public.event') IS NULL THEN
    RAISE EXCEPTION 'vaultwarden tables not created yet (first start running migrations?)';
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO :"role";
-- metrics
GRANT SELECT (uuid, enabled, verified_at, email, name) ON users TO :"role";
GRANT SELECT (user_uuid, atype, enabled) ON twofactor TO :"role";
GRANT SELECT (user_uuid) ON twofactor_incomplete TO :"role";
GRANT SELECT (uuid, name) ON organizations TO :"role";
GRANT SELECT (uuid, user_uuid, status, atype) ON users_organizations TO :"role";
GRANT SELECT (uuid) ON collections, groups TO :"role";
GRANT SELECT (atype, deleted_at) ON ciphers TO :"role";
GRANT SELECT (file_size) ON attachments TO :"role";
GRANT SELECT (atype) ON sends, devices TO :"role";
GRANT SELECT (status) ON emergency_access TO :"role";
-- events
GRANT SELECT ON event TO :"role";
