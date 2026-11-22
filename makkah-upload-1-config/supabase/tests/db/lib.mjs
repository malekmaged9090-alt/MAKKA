// Shared helpers: boots an in-process PostgreSQL (PGlite), applies the real migrations,
// and lets tests act as a given signed-in user (RLS applies) or as anon.
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "node:fs"; import path from "node:path"; import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
const here = path.dirname(fileURLToPath(import.meta.url));
export const MIGRATIONS = path.resolve(here, "../../migrations");

export async function boot({ migrate = true } = {}) {
  const db = new PGlite({ extensions: { pgcrypto } });
  // Minimal Supabase contract: roles, auth.users, auth.uid(), default grants (as Supabase does).
  await db.exec(`
    create role anon nologin; create role authenticated nologin; create role service_role nologin;
    create schema auth;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text, last_sign_in_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
    grant usage on schema public, auth to anon, authenticated;
    grant select on auth.users to authenticated;
    alter default privileges in schema public grant all on tables to anon, authenticated;
    alter default privileges in schema public grant all on sequences to anon, authenticated;
    alter default privileges in schema public grant execute on functions to anon, authenticated;`);
  if (!migrate) return db;
  const files = fs.readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort();
  for (const f of files) {
    try { await db.exec(fs.readFileSync(path.join(MIGRATIONS, f), "utf8")); }
    catch (e) { throw new Error(`migration ${f} failed: ${e.message}`); }
  }
  return db;
}
export const as = async (db, userId, fn) => {
  await db.exec(`select set_config('request.jwt.claim.sub', '${userId}', false); set role authenticated;`);
  try { return await fn(); } finally { await db.exec(`reset role; select set_config('request.jwt.claim.sub','',false);`); }
};
export const asAnon = async (db, fn) => { await db.exec(`set role anon`); try { return await fn(); } finally { await db.exec(`reset role`); } };
export const q = (db, s, p) => db.query(s, p).then((r) => r.rows);
export const rejects = async (p, re) => { try { await p; } catch (e) { assert.match(e.message, re); return; } assert.fail("expected an error matching " + re); };
export function runner(title) {
  let pass = 0, fail = 0;
  console.log(`\n${title}`);
  return {
    t: async (name, fn) => { try { await fn(); pass++; console.log("  ✓", name); } catch (e) { fail++; console.log("  ✗", name, "\n      ", String(e.message).split("\n").slice(0, 3).join(" | ")); } },
    done: () => { console.log(`  → ${pass} passed, ${fail} failed`); return fail; },
  };
}
export const uid = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, "0")}`;
