-- =====================================================================
-- !!! DESTRUCTIVE !!!  Deletes EVERYTHING in the "public" schema (all tables, data, functions).
-- Use only on a project that has no data you need (e.g. a failed first attempt).
-- It does NOT touch Authentication users. Afterwards run 01_ALL_IN_ONE.sql.
-- =====================================================================
drop schema if exists public cascade;
create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant all   on schema public to postgres, service_role;
alter default privileges in schema public grant all on tables    to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
