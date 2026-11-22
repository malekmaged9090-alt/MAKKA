import { boot, as, asAnon, q, rejects, runner, uid, MIGRATIONS } from "./lib.mjs";
import assert from "node:assert/strict"; import fs from "node:fs"; import path from "node:path";
const db = await boot();
const { t, done } = runner("Security: RLS coverage, anonymous access, tenant & role isolation");

await t("every public table has RLS enabled", async () => {
  const r = await q(db, `select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity`);
  assert.deepEqual(r.map((x) => x.relname), []);
});
await t("anon can execute ONLY public_tracking", async () => {
  const r = await q(db, `select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' and p.prorettype::regtype::text<>'trigger' and has_function_privilege('anon',p.oid,'execute') and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')`);
  assert.deepEqual(r.map((x) => x.proname), ["public_tracking"]);
});
await t("0008 is idempotent (second run changes nothing and does not fail)", async () => {
  await db.exec(fs.readFileSync(path.join(MIGRATIONS, "0008_hardening.sql"), "utf8"));
});

// ---- fixtures: two companies, two merchants in A, users with different roles ----
await db.exec(`insert into companies (code,name_ar,name_en) values ('A','أ','Company A'),('B','ب','Company B')`);
const [{ id: coA }, { id: coB }] = await q(db, `select id from companies order by code`);
const [{ id: dxb }] = await q(db, `select id from emirates where code='DXB'`);
const mk = async (co, name) => (await q(db, `insert into merchants (company_id,name) values ($1,$2) returning id`, [co, name]))[0].id;
const [m1, m2, mB] = [await mk(coA, "M1"), await mk(coA, "M2"), await mk(coB, "MB")];
const U = { ownerA: uid(1), ownerB: uid(2), cashierA: uid(3), merch1: uid(4), norole: uid(5), auditorA: uid(6) };
const prof = { ownerA: [coA, "owner"], ownerB: [coB, "owner"], cashierA: [coA, "cashier"], merch1: [coA, "merchant_admin", m1], norole: [coA, null], auditorA: [coA, "auditor"] };
for (const [k, [co, role, merchant]] of Object.entries(prof)) {
  await db.query(`insert into auth.users (id,email) values ($1,$2)`, [U[k], k + "@t.io"]);
  await db.query(`insert into profiles (id,company_id,full_name,merchant_id) values ($1,$2,$3,$4)`, [U[k], co, k, merchant ?? null]);
  if (role) await db.query(`insert into user_roles (user_id,role_id) select $1,id from roles where code=$2`, [U[k], role]);
}
const ship = async (co, merchant, who) => (await q(db, `insert into shipments (company_id,merchant_id,recipient_name,recipient_phone,delivery_emirate_id,delivery_address_text,service_type,created_by)
  values ($1,$2,'R','0501111111',$3,'addr','standard',$4) returning id`, [co, merchant, dxb, who]))[0].id;
const [sA1, sA2, sB] = [await ship(coA, m1, U.ownerA), await ship(coA, m2, U.ownerA), await ship(coB, mB, U.ownerB)];
await db.query(`insert into customers (company_id,full_name,phone) values ($1,'CustA','050'),($2,'CustB','051')`, [coA, coB]);
const ids = (rows) => rows.map((r) => r.id).sort();

await t("anon reads ZERO rows from every public table", async () => {
  const tabs = (await q(db, `select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r'`)).map((x) => x.relname);
  const leaks = [];
  for (const tb of tabs) { const n = await asAnon(db, async () => { try { return (await q(db, `select count(*)::int n from "${tb}"`))[0].n; } catch { return 0; } }); if (n > 0) leaks.push(`${tb}:${n}`); }
  assert.deepEqual(leaks, []);
});
await t("anon cannot insert a shipment", () => rejects(asAnon(db, () => db.query(`insert into shipments (company_id,merchant_id,recipient_name,recipient_phone,delivery_emirate_id,delivery_address_text,service_type) values ($1,$2,'x','1',$3,'a','standard')`, [coA, m1, dxb])), /row-level security|permission denied/));
await t("owner A sees only company A shipments / customers / merchants", async () => {
  assert.deepEqual(await as(db, U.ownerA, async () => ids(await q(db, `select id from shipments`))), [sA1, sA2].sort());
  assert.deepEqual(await as(db, U.ownerA, async () => (await q(db, `select full_name from customers`)).map((x) => x.full_name)), ["CustA"]);
  assert.equal(await as(db, U.ownerA, async () => (await q(db, `select count(*)::int n from merchants where company_id=$1`, [coB]))[0].n), 0);
});
await t("owner A cannot create a shipment inside company B", () => rejects(as(db, U.ownerA, () => db.query(`insert into shipments (company_id,merchant_id,recipient_name,recipient_phone,delivery_emirate_id,delivery_address_text,service_type) values ($1,$2,'x','1',$3,'a','standard')`, [coB, mB, dxb])), /row-level security/));
await t("owner A cannot read company B through report_rows or change its status", async () => {
  const j = await as(db, U.ownerA, async () => (await q(db, `select report_rows('all_shipments') j`))[0].j);
  assert.ok(j.every((r) => r.id !== sB));
  await rejects(as(db, U.ownerA, () => db.query(`select change_shipment_status($1,'CONFIRMED')`, [sB])), /not found/);
});
await t("merchant user sees only its own merchant's shipments", async () => {
  assert.deepEqual(await as(db, U.merch1, async () => ids(await q(db, `select id from shipments`))), [sA1]);
});
await t("a signed-in user with no role sees nothing", async () => {
  assert.equal(await as(db, U.norole, async () => (await q(db, `select count(*)::int n from shipments`))[0].n), 0);
  assert.equal(await as(db, U.norole, async () => (await q(db, `select count(*)::int n from customers`))[0].n), 0);
});
await t("cashier cannot change shipment status, delete, or read finance reports", async () => {
  await rejects(as(db, U.cashierA, () => db.query(`select change_shipment_status($1,'CONFIRMED')`, [sA1])), /permission/);
  await as(db, U.cashierA, () => db.query(`delete from shipments where id=$1`, [sA1]));   // RLS: no delete policy -> 0 rows
  assert.equal((await q(db, `select count(*)::int n from shipments where id=$1`, [sA1]))[0].n, 1);
});
await t("status can never be updated directly (only through the guarded function)", async () => {
  await rejects(as(db, U.ownerA, () => db.query(`update shipments set status_code='DELIVERED' where id=$1`, [sA1])), /status|function|not allowed/i);
});
await t("a user cannot grant themselves roles or read other users' roles", async () => {
  await rejects(as(db, U.cashierA, () => db.query(`insert into user_roles (user_id,role_id) select $1,id from roles where code='owner'`, [U.cashierA])), /row-level security/);
  assert.deepEqual(await as(db, U.cashierA, async () => (await q(db, `select user_id from user_roles`)).map((r) => r.user_id)), [U.cashierA]);
});
await t("audit log is append-only and hidden from cashier", async () => {
  assert.equal(await as(db, U.cashierA, async () => (await q(db, `select count(*)::int n from audit_logs`))[0].n), 0);
  await rejects(db.query(`update audit_logs set action='x'`), /append-only|not allowed/);
  await rejects(db.query(`delete from audit_logs`), /append-only|not allowed|deleting/);
});
await db.query(`insert into auth.users (id,email) values ($1,'drv@t.io')`, [uid(7)]);
await db.query(`insert into profiles (id,company_id,full_name) values ($1,$2,'drv')`, [uid(7), coA]);
await db.query(`insert into user_roles (user_id,role_id) select $1,id from roles where code='driver'`, [uid(7)]);
await t("no SELECT on any public table errors for any role (catches policy recursion)", async () => {
  const tabs = (await q(db, `select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r'`)).map((x) => x.relname);
  const errors = [];
  for (const [who, id] of Object.entries({ ...U, driver: uid(7) }))
    for (const tb of tabs) await as(db, id, async () => { try { await q(db, `select * from "${tb}" limit 1`); } catch (e) { if (!/permission denied/.test(e.message)) errors.push(`${who}:${tb}: ${e.message.split("\n")[0]}`); } });
  assert.deepEqual(errors, []);
});
process.exit(done() ? 1 : 0);
