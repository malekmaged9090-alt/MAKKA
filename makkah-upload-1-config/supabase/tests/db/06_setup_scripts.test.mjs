// The files you actually paste into the Supabase SQL Editor: ALL_IN_ONE, RESET, bootstrap.
import { boot, as, q, rejects, runner } from "./lib.mjs";
import assert from "node:assert/strict"; import fs from "node:fs"; import path from "node:path"; import { fileURLToPath } from "node:url";
import { buildAllInOne } from "../../../scripts/build-setup.mjs";
const setup = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../setup");
const read = (f) => fs.readFileSync(path.join(setup, f), "utf8");
const { t, done } = runner("Setup scripts for the Supabase SQL Editor");
const db = await boot({ migrate: false });
await t("01_ALL_IN_ONE.sql is up to date with the migrations", async () => { assert.equal(read("01_ALL_IN_ONE.sql"), buildAllInOne()); });
await t("01_ALL_IN_ONE.sql applies on an empty database; every table has RLS", async () => {
  await db.exec(read("01_ALL_IN_ONE.sql"));
  assert.deepEqual((await q(db, `select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity`)), []);
});
await t("a failing script leaves nothing half-applied (single transaction)", async () => {
  const fresh = await boot({ migrate: false });
  await rejects(fresh.exec(read("01_ALL_IN_ONE.sql").replace("-- ############ 0008_hardening.sql", "select 1/0; --")), /division by zero/);
  await fresh.exec("rollback").catch(() => {});
  assert.equal((await q(fresh, `select count(*)::int n from pg_tables where schemaname='public'`))[0].n, 0);
});
await t("00_RESET followed by 01_ALL_IN_ONE works again (re-install)", async () => {
  await db.exec(read("00_RESET_public_schema.sql")); assert.equal((await q(db, `select count(*)::int n from pg_tables where schemaname='public'`))[0].n, 0);
  await db.exec(read("01_ALL_IN_ONE.sql"));
  assert.deepEqual((await q(db, `select count(*)::int n from pg_tables where schemaname='public' and not rowsecurity`)).map((r) => r.n), [0]);
});
await t("verify_production.sql returns zero rows for every check", async () => {
  const stmts = read("../verify_production.sql").split(/;\s*\n/).map((s) => s.replace(/^(\s*--.*\n)+/, "").trim()).filter((s) => /^select/i.test(s));
  assert.ok(stmts.length >= 4);
  for (const s of stmts) assert.deepEqual((await db.query(s)).rows, [], s.slice(0, 60));
});
await t("bootstrap refuses the placeholder email and unknown users", async () => {
  await rejects(db.exec(read("02_bootstrap_admin.sql")), /Edit v_email first/);
  await rejects(db.exec(read("02_bootstrap_admin.sql").replace("CHANGE_ME@example.com", "ghost@x.io")), /No Authentication user/);
});
await t("bootstrap creates company + owner who can administer users; re-running is safe", async () => {
  await db.exec(`insert into auth.users (id,email) values ('00000000-0000-0000-0000-0000000000aa','Boss@Example.com')`);
  const sql = read("02_bootstrap_admin.sql").replace("CHANGE_ME@example.com", "boss@example.com");
  await db.exec(sql); await db.exec(sql);
  assert.equal((await q(db, `select count(*)::int n from companies`))[0].n, 1);
  const perms = await as(db, "00000000-0000-0000-0000-0000000000aa", async () => (await q(db, `select my_permissions() p`))[0].p);
  for (const p of ["users.manage", "shipments.create", "geo.manage", "finance.read"]) assert.ok(perms.includes(p), p);
  const list = await as(db, "00000000-0000-0000-0000-0000000000aa", () => q(db, `select email, roles from list_users()`));
  assert.deepEqual(list.map((r) => r.roles), [["owner"]]);
});
process.exit(done() ? 1 : 0);
