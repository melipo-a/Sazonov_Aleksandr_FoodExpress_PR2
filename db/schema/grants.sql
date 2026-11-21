DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
    ELSE
        ALTER ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
    END IF;
END;
$$ LANGUAGE plpgsql;

GRANT ALL PRIVILEGES ON SCHEMA sazonov_food TO inspector;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA sazonov_food FROM inspector;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sazonov_food TO inspector;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA sazonov_food TO inspector;
GRANT USAGE ON SCHEMA exts TO inspector;
GRANT EXECUTE ON FUNCTION exts.uuid_generate_v4() TO inspector;
GRANT USAGE ON SCHEMA pg_catalog, information_schema TO inspector;
