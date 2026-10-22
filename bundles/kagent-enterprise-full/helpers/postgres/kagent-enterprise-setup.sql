-- Vendored unchanged from solo-io/enterprise-kagent v1.0.0-alpha11,
-- services/solo-enterprise/migrations/postgres/setup/setup.sql. Run by 17-postgres.sh after
-- kagent-setup.sql. Re-vendor when the enterprise pin moves.
-- Prepares a PostgreSQL database for kagent-enterprise. Run it after kagent's own setup, which
-- creates the two roles the controller assumes, as a superuser or the database owner:
--
--   psql --single-transaction -f setup.sql \
--     -v kagent_owner_role=kagent_owner \
--     -v kagent_readwrite_role=kagent_readwrite \
--     -v enterprise_schema=enterprise \
--     -v agentevals_user=agentevals_user \
--     -v agentevals_password=<password>
--
-- Every variable is optional. The first four default to the value shown.
--
--   kagent_owner_role    the chart's config.database.owner.role.
--   kagent_readwrite_role
--                        the chart's config.database.readWrite.role.
--   enterprise_schema    the chart's enterprise.database.postgres.schema. It must differ from
--                        database.postgres.schema, because both hold a table named eval_set.
--   agentevals_user      the login agentevals connects as. Empty creates no login, for an
--                        install without agentevals.
--   agentevals_password  that login's password. A value sets or changes it. Empty clears it, for
--                        a certificate login. Omitted leaves the login's password as it is, so a
--                        rerun cannot clear a password set earlier or by hand.
--
-- The script creates the enterprise schema, owned by kagent_owner_role, or verifies an existing
-- one. The controller applies the enterprise migrations under that role, and the role holds no
-- CREATE on the database, so it cannot create the schema itself. Without it the controller exits
-- on "create schema enterprise: permission denied for database".
--
-- It grants kagent_readwrite_role USAGE on the schema, and row privileges on every table, sequence,
-- routine and type kagent_owner_role creates in it from then on, as kagent's own setup does for
-- kagent's schema. Every enterprise query runs as that role, so without the grants each one fails
-- with "permission denied", though the controller starts. The grants cover objects created after
-- the script runs, which on a new schema is all of them: the migrations and the trace partitions
-- the controller adds each day.
--
-- It also creates the agentevals login, NOINHERIT and with CONNECT and CREATE on the database.
-- agentevals runs CREATE SCHEMA IF NOT EXISTS for its own schema at startup, and PostgreSQL
-- checks the CREATE privilege before it checks whether the schema exists.
--
-- The script is idempotent. It fails rather than changes a schema that another role owns, or a
-- login with attributes other than the ones above.

\if :{?kagent_owner_role}
\else
\set kagent_owner_role kagent_owner
\endif
\if :{?kagent_readwrite_role}
\else
\set kagent_readwrite_role kagent_readwrite
\endif
\if :{?enterprise_schema}
\else
\set enterprise_schema enterprise
\endif
\if :{?agentevals_user}
\else
\set agentevals_user agentevals_user
\endif
-- Omitted and empty differ: psql tells them apart, and the DO block cannot.
\if :{?agentevals_password}
\set agentevals_password_given true
\else
\set agentevals_password_given false
\set agentevals_password ''
\endif

SELECT
    set_config('kagent_enterprise.setup_owner_role', :'kagent_owner_role', true) AS owner_role,
    set_config('kagent_enterprise.setup_readwrite_role', :'kagent_readwrite_role', true) AS readwrite_role,
    set_config('kagent_enterprise.setup_schema', :'enterprise_schema', true) AS schema,
    set_config('kagent_enterprise.setup_agentevals_user', :'agentevals_user', true) AS agentevals_user,
    set_config('kagent_enterprise.setup_agentevals_password', :'agentevals_password', true) AS agentevals_password,
    set_config('kagent_enterprise.setup_agentevals_password_given', :'agentevals_password_given', true) AS agentevals_password_given
\gset

DO $setup$
DECLARE
    owner_role text := current_setting('kagent_enterprise.setup_owner_role');
    readwrite_role text := current_setting('kagent_enterprise.setup_readwrite_role');
    schema_name text := current_setting('kagent_enterprise.setup_schema');
    agentevals_user text := current_setting('kagent_enterprise.setup_agentevals_user');
    agentevals_password text := NULLIF(current_setting('kagent_enterprise.setup_agentevals_password'), '');
    agentevals_password_given boolean := current_setting('kagent_enterprise.setup_agentevals_password_given')::boolean;
    role_attrs record;
    schema_owner text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('kagent-enterprise:setup:' || schema_name, 0));

    -- The controller splices the schema into SQL text and accepts only a plain identifier, so a
    -- name it would refuse fails here rather than at the controller's first query.
    IF schema_name !~ '^[a-z_][a-z0-9_]*$' THEN
        RAISE EXCEPTION 'enterprise schema "%" must be a lowercase identifier', schema_name;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = owner_role) THEN
        RAISE EXCEPTION 'PostgreSQL role "%" does not exist; run kagent''s database setup first', owner_role;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = readwrite_role) THEN
        RAISE EXCEPTION 'PostgreSQL role "%" does not exist; run kagent''s database setup first', readwrite_role;
    END IF;

    SELECT pg_get_userbyid(nspowner) INTO schema_owner FROM pg_namespace WHERE nspname = schema_name;
    IF NOT FOUND THEN
        EXECUTE format('CREATE SCHEMA %I AUTHORIZATION %I', schema_name, owner_role);
    ELSIF schema_owner <> owner_role THEN
        RAISE EXCEPTION 'PostgreSQL schema "%" is owned by "%", not "%"', schema_name, schema_owner, owner_role;
    END IF;

    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', schema_name);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', schema_name, readwrite_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', owner_role, schema_name, readwrite_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', owner_role, schema_name, readwrite_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT EXECUTE ON ROUTINES TO %I', owner_role, schema_name, readwrite_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT USAGE ON TYPES TO %I', owner_role, schema_name, readwrite_role);

    IF agentevals_user <> '' THEN
        SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolinherit
          INTO role_attrs FROM pg_roles WHERE rolname = agentevals_user;
        IF NOT FOUND THEN
            EXECUTE format('CREATE ROLE %I LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION', agentevals_user);
        ELSIF NOT role_attrs.rolcanlogin OR role_attrs.rolsuper OR role_attrs.rolcreatedb
           OR role_attrs.rolcreaterole OR role_attrs.rolreplication OR role_attrs.rolinherit THEN
            RAISE EXCEPTION 'managed PostgreSQL role "%" conflicts with the required attributes', agentevals_user;
        END IF;
        IF agentevals_password_given THEN
            EXECUTE format('ALTER ROLE %I PASSWORD %L', agentevals_user, agentevals_password);
        END IF;
        EXECUTE format('GRANT CONNECT, CREATE ON DATABASE %I TO %I', current_database(), agentevals_user);
    END IF;
END
$setup$;
