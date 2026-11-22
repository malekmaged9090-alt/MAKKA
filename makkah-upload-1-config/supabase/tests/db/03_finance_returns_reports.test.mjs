// Runs the finance (0004) and returns/ops (0005) SQL test scripts, then smoke-tests all 18 reports.
// The two .sql scripts were written against an older stand-in schema, so a TEST-ONLY shim adds the few
// columns they insert; it is never part of a production migration.
import { boot, as, q, runner } from "./lib.mjs";
import fs from "node:fs"; import path from "node:path"; import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
const here = path.dirname(fileURLToPath(import.meta.url));
const db = await boot();
const { t, done } = runner("Finance (COD, ledgers, settlements), returns, bulk scan, reports");
await db.exec(`alter table profiles add column if not exists email text;
  alter table branches add column if not exists code text; alter table branches add column if not exists area_id uuid;
  alter table customers add column if not exists emirate_id uuid; alter table customers add column if not exists area_id uuid; alter table customers add column if not exists address_text text;`);
for (const f of ["0004_finance_tests.sql", "0005_returns_tests.sql"]) {
  await t(`SQL script ${f} (every block raises on failure)`, async () => {
    const sql = fs.readFileSync(path.join(here, "..", f), "utf8").replace(/^\\.*$/mg, "")
      .replace(/insert into emirates \(id, code, name_ar, name_en\)\s*values \('([^']+)', 'DXB'[^;]*;/s, "update emirates set id='$1' where code='DXB';");
    await db.exec(sql);
  });
}
const owner = "aaaaaaaa-0000-0000-0000-000000000001";
for (const r of ["all_shipments", "daily_shipments", "delivered", "failed", "returns", "driver_performance", "merchant_performance", "by_emirate", "by_area", "daily_cod", "driver_cash", "merchant_statement", "settlements", "finance", "overdue", "attempts", "branch_movements", "barcode_reprints"])
  await t(`report_rows('${r}') runs against the real schema`, async () => { await as(db, owner, () => db.query(`select report_rows($1)`, [r])); });
await t("finance_overview and cod_reconciliation run", async () => {
  await as(db, owner, () => db.query(`select finance_overview()`)); await as(db, owner, () => db.query(`select cod_reconciliation(current_date)`));
});
await t("notification trigger produced in-app notifications for status changes", async () => {
  assert.ok((await q(db, `select count(*)::int n from notifications`))[0].n > 0);
});
process.exit(done() ? 1 : 0);
