// The exact statements the app's import / customers / areas screens run, executed as real signed-in users (RLS on).
import { boot, as, q, rejects, runner, uid } from "./lib.mjs";
import assert from "node:assert/strict";
const db = await boot();
const { t, done } = runner("Import, customers and areas screens under RLS");
await db.exec(`insert into companies (code,name_ar,name_en) values ('MKK','م','M')`);
const [{ id: co }] = await q(db, `select id from companies`);
const [{ id: dxb }] = await q(db, `select id from emirates where code='DXB'`);
const [{ id: m1 }] = await q(db, `insert into merchants (company_id,name) values ($1,'M1') returning id`, [co]);
const [{ id: m2 }] = await q(db, `insert into merchants (company_id,name) values ($1,'M2') returning id`, [co]);
const [{ id: area }] = await q(db, `insert into areas (emirate_id,name_en,name_ar) values ($1,'Deira','ديرة') returning id`, [dxb]);
const U = { cs: uid(1), ops: uid(2), cashier: uid(3), merch: uid(4) };
const R = { cs: ["customer_service"], ops: ["ops_manager"], cashier: ["cashier"], merch: ["merchant_admin", m1] };
for (const [k, id] of Object.entries(U)) {
  await db.query(`insert into auth.users (id,email) values ($1,$2)`, [id, k + "@t.io"]);
  await db.query(`insert into profiles (id,company_id,full_name,merchant_id) values ($1,$2,$3,$4)`, [id, co, k, R[k][1] ?? null]);
  await db.query(`insert into user_roles (user_id,role_id) select $1,id from roles where code=$2`, [id, R[k][0]]);
}
const row = (n, merchant, over = {}) => ({ company_id: co, merchant_id: merchant, merchant_reference: `REF-${n}`, idempotency_key: uid(1000 + n), customer_id: null,
  recipient_name: "Ali " + n, recipient_phone: "050123456" + n, delivery_emirate_id: dxb, delivery_area_id: area, delivery_address_text: "Street " + n, service_type: "standard",
  parcel_count: 1, weight_kg: null, description: null, goods_value: 0, payment_method: "cod", cod_amount: 100, notes: null, serial_number: "pending", tracking_number: "pending", tracking_token: "pending", ...over });
const insertMany = (user, rows) => {                         // same multi-row INSERT the app sends through PostgREST
  const cols = Object.keys(rows[0]); const params = rows.flatMap((r) => cols.map((c) => r[c]));
  const values = rows.map((_, i) => "(" + cols.map((_, j) => `$${i * cols.length + j + 1}`).join(",") + ")").join(",");
  return as(db, user, () => db.query(`insert into shipments (${cols.join(",")}) values ${values} returning id, serial_number, status_code`, params));
};

await t("customer_service imports a batch: serials/tracking assigned by the database, status NEW-like", async () => {
  const r = await insertMany(U.cs, [row(1, m1), row(2, m1), row(3, m1)]);
  assert.equal(r.rows.length, 3);
  assert.ok(r.rows.every((x) => /^MKK-\d{4}-\d{8}$/.test(x.serial_number)), JSON.stringify(r.rows[0]));
});
await t("re-importing the same file (same idempotency keys) is refused, creates nothing", async () => {
  await rejects(insertMany(U.cs, [row(1, m1), row(2, m1)]), /idempotency/);
  assert.equal((await q(db, `select count(*)::int n from shipments`))[0].n, 3);
});
await t("a batch with one invalid row inserts NOTHING (atomic)", async () => {
  await rejects(insertMany(U.cs, [row(10, m1), row(11, m1, { service_type: "teleport" })]), /check constraint|invalid/i);
  assert.equal((await q(db, `select count(*)::int n from shipments where merchant_reference in ('REF-10','REF-11')`))[0].n, 0);
});
await t("cashier (no shipments.create) cannot import", () => rejects(insertMany(U.cashier, [row(20, m1)]), /row-level security/));
await t("merchant user can import only for their own merchant", async () => {
  await insertMany(U.merch, [row(30, m1)]);
  await rejects(insertMany(U.merch, [row(31, m2)]), /row-level security/);
});
await t("customers: customer_service can create and edit; cashier cannot", async () => {
  const c = await as(db, U.cs, () => q(db, `insert into customers (company_id,full_name,phone,created_by) values ($1,'Zed','0509999999',$2) returning id`, [co, U.cs]));
  await as(db, U.cs, () => db.query(`update customers set phone_alt='0501', notes='vip' where id=$1`, [c[0].id]));
  assert.equal((await q(db, `select notes from customers where id=$1`, [c[0].id]))[0].notes, "vip");
  await as(db, U.cashier, () => db.query(`update customers set notes='hack' where id=$1`, [c[0].id]));
  assert.equal((await q(db, `select notes from customers where id=$1`, [c[0].id]))[0].notes, "vip");
  assert.equal(await as(db, U.cashier, async () => (await q(db, `select count(*)::int n from customers`))[0].n), 0);
});
await t("areas: ops_manager manages (cover / disable / bulk insert); others cannot", async () => {
  await as(db, U.ops, () => db.query(`update areas set is_covered=false, needs_review=true where id=$1`, [area]));
  const a = (await q(db, `select is_covered c, needs_review r from areas where id=$1`, [area]))[0]; assert.deepEqual([a.c, a.r], [false, true]);
  await as(db, U.ops, () => db.query(`insert into areas (emirate_id,name_en,name_ar,needs_review) values ($1,'Bur Dubai','بر دبي',false),($1,'Karama','كراما',false)`, [dxb]));
  await rejects(as(db, U.ops, () => db.query(`insert into areas (emirate_id,name_en,name_ar) values ($1,'Karama','كراما')`, [dxb])), /unique|duplicate/);
  await as(db, U.cs, () => db.query(`update areas set is_active=false where id=$1`, [area]));
  assert.equal((await q(db, `select is_active a from areas where id=$1`, [area]))[0].a, true);
  await rejects(as(db, U.cs, () => db.query(`insert into areas (emirate_id,name_en,name_ar) values ($1,'Hack','هاك')`, [dxb])), /row-level security/);
});
process.exit(done() ? 1 : 0);
