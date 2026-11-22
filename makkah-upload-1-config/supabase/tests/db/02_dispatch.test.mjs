import { boot, as, q as qq, rejects, runner } from "./lib.mjs";
import assert from "node:assert/strict";
const db = await boot();
const { t, done } = runner("Dispatch, driver app, proof of delivery, public tracking (real RLS)");
const rej = rejects; const q = (s, p) => qq(db, s, p);
const console_log = console.log; // section markers from the original script are cosmetic
// ---------- fixtures (superuser) ----------
const U = (n) => `00000000-0000-0000-0000-0000000000${n}`;
const users = { owner: U(10), disp: U(11), cashier: U(12), drvA: U(13), drvB: U(14), merch: U(15) };
await db.exec(`insert into companies (code,name_ar,name_en) values ('MKK','مكة','MAKKAH')`);
const [{ id: co }] = await q(`select id from companies`);
for (const [k, id] of Object.entries(users)) await db.query(`insert into auth.users (id,email) values ($1,$2)`, [id, `${k}@t.io`]);
const roleOf = { owner: "owner", disp: "dispatcher", cashier: "cashier", drvA: "driver", drvB: "driver", merch: "merchant_admin" };
for (const [k, id] of Object.entries(users)) {
  await db.query(`insert into profiles (id,company_id,full_name) values ($1,$2,$3)`, [id, co, k]);
  await db.query(`insert into user_roles (user_id,role_id) select $1,id from roles where code=$2`, [id, roleOf[k]]);
}
const [{ id: dxb }] = await q(`select id from emirates where code='DXB'`);
const [{ id: auh }] = await q(`select id from emirates where code='AUH'`);
const [{ id: area }] = await q(`insert into areas (emirate_id,name_en,name_ar) values ($1,'Deira','ديرة') returning id`, [dxb]);
const [{ id: merchant }] = await q(`insert into merchants (company_id,name) values ($1,'Shop') returning id`, [co]);
const [{ id: cust }] = await q(`insert into customers (company_id,full_name,phone) values ($1,'Ali','0501234567') returning id`, [co]);
const [{ id: dA }] = await q(`insert into drivers (company_id,full_name,phone,status,user_id) values ($1,'Driver A','050',$2,$3) returning id`, [co, "available", users.drvA]);
const [{ id: dB }] = await q(`insert into drivers (company_id,full_name,phone,status,user_id) values ($1,'Driver B','051',$2,$3) returning id`, [co, "available", users.drvB]);
const mkShipment = async (emirate = dxb, cod = 100) => {
  const [{ id }] = await q(`insert into shipments (company_id,merchant_id,customer_id,recipient_name,recipient_phone,delivery_emirate_id,delivery_area_id,delivery_address_text,service_type,cod_amount)
    values ($1,$2,$3,'Ali','0501234567',$4,$5,'Street 1','standard',$6) returning id`, [co, merchant, cust, emirate, emirate === dxb ? area : null, cod]);
  await db.exec(`select set_config('app.status_via_fn','on',false)`);
  await db.query(`update shipments set status_code='READY_FOR_DISPATCH' where id=$1`, [id]);
  await db.exec(`select set_config('app.status_via_fn','',false)`);
  return id;
};
const status = async (id) => (await q(`select status_code s from shipments where id=$1`, [id]))[0].s;
const call = (u, sql, p) => as(db, u, () => db.query(sql, p));


const s1 = await mkShipment();
await t("cashier cannot call change_shipment_status (Phase 1 gap fixed)", () => rej(call(users.cashier, `select change_shipment_status($1,'ON_HOLD','x')`, [s1]), /permission shipments.status required|not found/));
await t("driver cannot call internal _change_status directly", () => rej(call(users.drvA, `select _change_status($1,'ON_HOLD','x')`, [s1]), /permission denied/));
await t("nobody can call next_shipment_serial / create_parcels", async () => {
  await rej(call(users.owner, `select next_shipment_serial($1)`, [co]), /permission denied/);
  await rej(call(users.owner, `select create_parcels($1)`, [s1]), /permission denied/);
});
await t("driver sees only own driver row", async () => {
  const r = await as(db, users.drvA, () => q(`select id from drivers`));
  assert.deepEqual(r.map((x) => x.id), [dA]);
});
await t("driver sees no shipment before assignment", async () => {
  assert.equal((await as(db, users.drvA, () => q(`select id from shipments`))).length, 0);
});


await t("assign fails when driver does not cover the area", () => rej(call(users.disp, `select assign_shipments($1,$2)`, [dA, [s1]]), /does not cover/));
await db.query(`insert into driver_area_assignments (driver_id,area_id) values ($1,$2)`, [dA, area]);
await db.query(`insert into driver_area_assignments (driver_id,emirate_id) values ($1,$2)`, [dB, dxb]);
let manifest;
await t("assign succeeds with coverage; manifest + status + assignment", async () => {
  const [{ assign_shipments }] = (await call(users.disp, `select assign_shipments($1,$2)`, [dA, [s1]])).rows;
  manifest = assign_shipments;
  assert.equal(await status(s1), "ASSIGNED_TO_DRIVER");
  assert.match((await q(`select manifest_no from dispatch_manifests where id=$1`, [manifest]))[0].manifest_no, /^DM-\d{4}-000001$/);
  assert.equal((await q(`select count(*)::int n from shipment_assignments where shipment_id=$1 and is_current`, [s1]))[0].n, 1);
});
await t("double assignment is rejected", () => rej(call(users.disp, `select assign_shipments($1,$2)`, [dB, [s1]]), /not ready for dispatch/));
await t("cashier cannot assign", () => rej(call(users.cashier, `select assign_shipments($1,$2)`, [dA, [s1]]), /permission dispatch.assign/));
await t("failed batch is atomic (second shipment bad => no manifest, first stays READY)", async () => {
  const a = await mkShipment(), bad = await mkShipment(auh);
  const before = (await q(`select count(*)::int n from dispatch_manifests`))[0].n;
  await rej(call(users.disp, `select assign_shipments($1,$2)`, [dB, [a, bad]]), /does not cover/);
  assert.equal(await status(a), "READY_FOR_DISPATCH");
  assert.equal((await q(`select count(*)::int n from dispatch_manifests`))[0].n, before);
});
await t("auto_dispatch picks the least-loaded covering driver", async () => {
  const a = await mkShipment(), b = await mkShipment();
  const [{ auto_dispatch }] = (await call(users.disp, `select auto_dispatch($1)`, [[a, b]])).rows;
  assert.equal(auto_dispatch, 2);
  const rows = await q(`select driver_id, count(*)::int n from shipment_assignments where shipment_id = any($1) and is_current group by 1`, [[a, b]]);
  // A already holds s1 (load 1), B holds 0: first goes to B, then loads tie (1-1) and the lower driver_no (A) wins => balanced 1/1
  assert.deepEqual(Object.fromEntries(rows.map((r) => [r.driver_id, r.n])), { [dA]: 1, [dB]: 1 });
});
await t("reassign requires reason and moves to new driver", async () => {
  await rej(call(users.disp, `select reassign_shipment($1,$2,'')`, [s1, dB]), /reason required/);
  await call(users.disp, `select reassign_shipment($1,$2,'driver sick')`, [s1, dB]);
  assert.equal((await q(`select driver_id from shipment_assignments where shipment_id=$1 and is_current`, [s1]))[0].driver_id, dB);
  assert.equal((await q(`select count(*)::int n from shipment_assignments where shipment_id=$1`, [s1]))[0].n, 2);
});


await t("driver A cannot touch a shipment assigned to B", () => rej(call(users.drvA, `select driver_accept($1)`, [s1]), /not your shipment/));
await t("driver B sees the shipment (RLS) and A does not", async () => {
  assert.equal((await as(db, users.drvB, () => q(`select id from shipments where id=$1`, [s1]))).length, 1);
  assert.equal((await as(db, users.drvA, () => q(`select id from shipments where id=$1`, [s1]))).length, 0);
});
await t("out for delivery", async () => { await call(users.drvB, `select driver_out_for_delivery($1)`, [s1]); assert.equal(await status(s1), "OUT_FOR_DELIVERY"); });
await t("deliver: amount differs from COD without note is rejected", () => rej(call(users.drvB, `select driver_deliver($1,'Ali',50,'cash',null)`, [s1]), /differs from COD/));
await t("deliver: receiver name required", () => rej(call(users.drvB, `select driver_deliver($1,'',100,'cash',null)`, [s1]), /receiver name/));
await t("deliver ok: status, POD, payment_status, customer counter", async () => {
  await call(users.drvB, `select driver_deliver($1,'Ali',100,'cash',null)`, [s1]);
  assert.equal(await status(s1), "DELIVERED");
  assert.equal((await q(`select collected_amount::int a from proof_of_delivery where shipment_id=$1`, [s1]))[0].a, 100);
  assert.equal((await q(`select payment_status p from shipments where id=$1`, [s1]))[0].p, "collected");
  assert.equal((await q(`select delivered_count d from customers where id=$1`, [cust]))[0].d, 1);
});
await t("delivered shipment cannot be delivered twice", () => rej(call(users.drvB, `select driver_deliver($1,'Ali',100,'cash',null)`, [s1]), /not your shipment|not allowed|permission/));
await t("proof_of_delivery is immutable", () => rej(db.query(`update proof_of_delivery set collected_amount=0`), /append-only|not allowed/));
await t("failed attempt: reschedule needs date; refusal bumps counter", async () => {
  const f = await mkShipment(); await call(users.disp, `select assign_shipments($1,$2)`, [dB, [f]]);
  await call(users.drvB, `select driver_out_for_delivery($1)`, [f]);
  await rej(call(users.drvB, `select driver_fail($1,'RESCHEDULED','asked later',null,null)`, [f]), /new date required/);
  await call(users.drvB, `select driver_fail($1,'CUSTOMER_REFUSED','refused')`, [f]);
  assert.equal(await status(f), "CUSTOMER_REFUSED");
  assert.equal((await q(`select refused_count r from customers where id=$1`, [cust]))[0].r, 1);
  assert.equal((await q(`select attempt_no n from failed_delivery_attempts where shipment_id=$1`, [f]))[0].n, 1);
});


const [{ tracking_number: tn, tracking_token: tk }] = await q(`select tracking_number, tracking_token from shipments where id=$1`, [s1]);
await t("anon with number+token gets data without personal fields", async () => {
  await db.exec(`set role anon`);
  const [{ public_tracking: j }] = (await db.query(`select public_tracking($1,$2)`, [tn, tk])).rows;
  await db.exec(`reset role`);
  assert.equal(j.serial, tn);
  const txt = JSON.stringify(j);
  for (const bad of ["0501234567", "Ali", "Street 1", "cod", "100"]) assert.ok(!txt.includes(`"${bad}"`) && !txt.includes(bad === "100" ? '"cod' : bad), "leaks " + bad);
  assert.ok(j.events.length >= 1);
});
await t("wrong token returns null", async () => {
  await db.exec(`set role anon`);
  const [{ public_tracking: j }] = (await db.query(`select public_tracking($1,'nope')`, [tn])).rows;
  await db.exec(`reset role`); assert.equal(j, null);
});


// ---- regression: dispatch load must ignore shipments that are already delivered ----
await t("auto_dispatch ignores delivered shipments when computing driver load", async () => {
  // Fresh pair of drivers in a new area so earlier test data cannot interfere.
  const [{ id: area2 }] = await q(`insert into areas (emirate_id,name_en,name_ar) values ($1,'Satwa','السطوة') returning id`, [dxb]);
  const [{ id: x1 }] = await q(`insert into drivers (company_id,full_name,phone,status) values ($1,'LoadA','1','available') returning id`, [co]);   // lower driver_no
  const [{ id: x2 }] = await q(`insert into drivers (company_id,full_name,phone,status) values ($1,'LoadB','2','available') returning id`, [co]);
  for (const d of [x1, x2]) await db.query(`insert into driver_area_assignments (driver_id,area_id) values ($1,$2)`, [d, area2]);
  const mk2 = async () => { const [{ id }] = await q(`insert into shipments (company_id,merchant_id,customer_id,recipient_name,recipient_phone,delivery_emirate_id,delivery_area_id,delivery_address_text,service_type,cod_amount)
      values ($1,$2,$3,'Ali','0501234567',$4,$5,'Street 1','standard',0) returning id`, [co, merchant, cust, dxb, area2]);
    await db.exec(`select set_config('app.status_via_fn','on',false)`); await db.query(`update shipments set status_code='READY_FOR_DISPATCH' where id=$1`, [id]); await db.exec(`select set_config('app.status_via_fn','',false)`); return id; };
  const a = await mk2();                                   // LoadB (x2) takes a delivered shipment: its assignment stays is_current=true
  await db.query(`select set_config('request.jwt.claim.sub','${users.disp}',false)`);
  await as(db, users.disp, () => db.query(`select assign_shipments($1,$2)`, [x2, [a]]));
  await db.exec(`select set_config('app.status_via_fn','on',false)`); await db.query(`update shipments set status_code='DELIVERED' where id=$1`, [a]); await db.exec(`select set_config('app.status_via_fn','',false)`);
  const b = await mk2();                                   // LoadA (x1) holds one ACTIVE shipment
  await as(db, users.disp, () => db.query(`select assign_shipments($1,$2)`, [x1, [b]]));
  const c = await mk2();                                   // old logic: tie 1-1 -> lower driver_no (x1); correct logic: x2 has 0 active -> x2
  await as(db, users.disp, () => db.query(`select auto_dispatch($1)`, [[c]]));
  assert.equal((await q(`select driver_id from shipment_assignments where shipment_id=$1 and is_current`, [c]))[0].driver_id, x2);
});
process.exit(done() ? 1 : 0);
