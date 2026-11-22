import { boot, as, asAnon, q, rejects, runner, uid } from "./lib.mjs";
import assert from "node:assert/strict";
const db = await boot();
const { t, done } = runner("User administration: provisioning, escalation, last-owner, company scope");
await db.exec(`insert into companies (code,name_ar,name_en) values ('A','أ','A'),('B','ب','B')`);
const [{ id: coA }, { id: coB }] = await q(db, `select id from companies order by code`);
const [{ id: m1 }] = await q(db, `insert into merchants (company_id,name) values ($1,'M1') returning id`, [coA]);
const [{ id: mB }] = await q(db, `insert into merchants (company_id,name) values ($1,'MB') returning id`, [coB]);
const U = { owner: uid(1), hr: uid(2), cashier: uid(3), ownerB: uid(4), owner2: uid(5) };
const role = { owner: ["owner", coA], hr: ["ops_manager", coA], cashier: ["cashier", coA], ownerB: ["owner", coB], owner2: ["owner", coA] };
for (const [k, id] of Object.entries(U)) { await db.query(`insert into auth.users (id,email) values ($1,$2)`, [id, `${k}@t.io`]); await db.query(`insert into profiles (id,company_id,full_name) values ($1,$2,$3)`, [id, role[k][1], k]); await db.query(`insert into user_roles (user_id,role_id) select $1,id from roles where code=$2`, [id, role[k][0]]); }
// an ops_manager that ALSO has users.manage but is not an owner (to test escalation)
await db.exec(`insert into permissions (code,description) values ('users.manage','x') on conflict do nothing; insert into role_permissions (role_id,permission_id) select r.id,p.id from roles r, permissions p where r.code='ops_manager' and p.code='users.manage' on conflict do nothing`);
const newAcct = async (email) => { const [{ id }] = await q(db, `insert into auth.users (id,email) values (gen_random_uuid(),$1) returning id`, [email]); return id; };
const call = (u, sql, p) => as(db, u, () => db.query(sql, p));

await t("my_permissions returns the caller's permission codes only", async () => {
  const c = await as(db, U.cashier, async () => (await q(db, `select my_permissions() p`))[0].p);
  assert.ok(c.length > 0 && !c.includes("users.manage") && !c.includes("finance.manage"));
  assert.ok((await as(db, U.owner, async () => (await q(db, `select my_permissions() p`))[0].p)).includes("users.manage"));
});
await t("cashier cannot administer users", async () => {
  await rejects(call(U.cashier, `select list_users()`), /users.manage/);
  await rejects(call(U.cashier, `select provision_user('x@t.io','X',array['cashier'])`), /users.manage/);
});
await t("direct writes to profiles / user_roles are blocked even for owners", async () => {
  await call(U.owner, `update profiles set is_active=false where id=$1`, [U.cashier]);            // RLS: no UPDATE policy -> 0 rows
  assert.equal((await q(db, `select is_active a from profiles where id=$1`, [U.cashier]))[0].a, true);
  await rejects(call(U.owner, `insert into user_roles (user_id,role_id) select $1,id from roles where code='owner'`, [U.cashier]), /row-level security/);
  await rejects(call(U.owner, `insert into profiles (id,company_id,full_name) values (gen_random_uuid(),$1,'x')`, [coA]), /row-level security|foreign key/);
  assert.equal((await q(db, `select count(*)::int n from user_roles ur join roles r on r.id=ur.role_id where ur.user_id=$1 and r.code='owner'`, [U.cashier]))[0].n, 0);
});
await t("provision_user: needs an existing auth account", () => rejects(call(U.owner, `select provision_user('nobody@t.io','N',array['cashier'])`), /no auth account/));
await t("provision_user links an auth account with roles; list_users shows it", async () => {
  await newAcct("new@t.io");
  await call(U.owner, `select provision_user('NEW@t.io','New Cashier',array['cashier','warehouse'])`);
  const rows = await as(db, U.owner, async () => (await q(db, `select email, roles from list_users() where email='new@t.io'`)));
  assert.deepEqual(rows[0].roles, ["cashier", "warehouse"]);
  await rejects(call(U.owner, `select provision_user('new@t.io','Again',array['cashier'])`), /already registered/);
});
await t("list_users is limited to the caller's company", async () => {
  const emails = await as(db, U.owner, async () => (await q(db, `select email from list_users()`)).map((r) => r.email));
  assert.ok(!emails.includes("ownerB@t.io") && emails.includes("owner@t.io"));
});
await t("a non-owner admin cannot grant owner, nor touch an owner", async () => {
  await newAcct("e1@t.io");
  await rejects(call(U.hr, `select provision_user('e1@t.io','E',array['owner'])`), /only an owner/);
  await rejects(call(U.hr, `select set_user_roles($1,array['cashier'])`, [U.owner]), /only an owner/);
  await rejects(call(U.hr, `select set_user_active($1,false)`, [U.owner]), /only an owner/);
});
await t("nobody can change their own roles or deactivate themselves", async () => {
  await rejects(call(U.owner, `select set_user_roles($1,array['cashier'])`, [U.owner]), /your own roles/);
  await rejects(call(U.owner, `select set_user_active($1,false)`, [U.owner]), /yourself/);
});
await t("an owner can demote or deactivate ANOTHER owner, but a lone owner can never remove themselves", async () => {
  await call(U.owner, `select set_user_roles($1,array['cashier'])`, [U.owner2]);
  assert.deepEqual((await q(db, `select r.code from user_roles ur join roles r on r.id=ur.role_id where ur.user_id=$1`, [U.owner2])).map((r) => r.code), ["cashier"]);
  await db.exec(`delete from user_roles where user_id='${U.owner2}'; insert into user_roles (user_id,role_id) select '${U.owner2}',id from roles where code='owner'`);   // restore (superuser)
  await call(U.owner, `select set_user_active($1,false)`, [U.owner2]);
  assert.equal((await q(db, `select is_active a from profiles where id=$1`, [U.owner2]))[0].a, false);
  await call(U.owner, `select set_user_active($1,true)`, [U.owner2]);
  await rejects(call(U.owner, `select set_user_roles($1,array['cashier'])`, [U.owner]), /your own roles/);     // so the last owner cannot lock the company out
});
await t("merchant roles need a merchant of the same company; staff roles must not have one", async () => {
  await newAcct("m@t.io");
  await rejects(call(U.owner, `select provision_user('m@t.io','M',array['merchant_admin'])`), /merchant is required/);
  await rejects(call(U.owner, `select provision_user('m@t.io','M',array['merchant_admin'],$1)`, [mB]), /merchant not found/);
  await rejects(call(U.owner, `select provision_user('m@t.io','M',array['cashier'],$1)`, [m1]), /only be set for merchant roles/);
  await rejects(call(U.owner, `select provision_user('m@t.io','M',array['merchant_admin','cashier'],$1)`, [m1]), /cannot be combined/);
  await call(U.owner, `select provision_user('m@t.io','Merchant User',array['merchant_admin'],$1)`, [m1]);
});
await t("unknown roles are rejected; deactivated users lose all permissions", async () => {
  await rejects(call(U.owner, `select set_user_roles($1,array['wizard'])`, [U.cashier]), /unknown role/);
  await call(U.owner, `select set_user_active($1,false)`, [U.cashier]);
  assert.deepEqual(await as(db, U.cashier, async () => (await q(db, `select my_permissions() p`))[0].p), []);
  await call(U.owner, `select set_user_active($1,true)`, [U.cashier]);
});
await t("owner of company B cannot see or edit company A users", async () => {
  await rejects(call(U.ownerB, `select set_user_roles($1,array['cashier'])`, [U.cashier]), /user not found/);
  await rejects(call(U.ownerB, `select set_user_active($1,false)`, [U.cashier]), /user not found/);
});
await t("anonymous visitors cannot call any user function", async () => {
  for (const f of ["my_permissions()", "list_users()", "provision_user('a@b.c','x',array['cashier'])", "set_user_active(gen_random_uuid(),true)"])
    await rejects(asAnon(db, () => db.query(`select ${f}`)), /permission denied/);
});
await t("role and profile changes are written to the audit log", async () => {
  assert.ok((await q(db, `select count(*)::int n from audit_logs where table_name in ('user_roles','profiles')`))[0].n > 0);
});
process.exit(done() ? 1 : 0);
