import ExcelJS from "exceljs";
import assert from "node:assert/strict";
import { buildShipmentPreview } from "../../src/lib/shipments-import";
import { readTable } from "../../src/lib/xlsx";

const emirates = [{ id: "e1", code: "DXB", name_en: "Dubai", name_ar: "دبي" }, { id: "e2", code: "AUH", name_en: "Abu Dhabi", name_ar: "أبوظبي" }];
const areas = [
  { id: "a1", emirate_id: "e1", name_en: "Deira", name_ar: "ديرة", is_covered: true, is_active: true },
  { id: "a2", emirate_id: "e1", name_en: "Far Place", name_ar: "بعيدة", is_covered: false, is_active: true },
];
const wb = new ExcelJS.Workbook(); const ws = wb.addWorksheet("s");
ws.addRow(["Recipient_Name", "الهاتف", "الإمارة", "area", "address", "service", "payment", "cod", "parcels", "reference"]);
ws.addRow(["Ali Hassan", "0501234567", "DXB", "Deira", "Street 1", "express", "cod", 150, 2, "R-1"]);        // ok (line 2)
ws.addRow(["Sara", "0507654321", "دبي", "", "Villa 4", "", "", 0, "", "R-1"]);                              // duplicate ref inside file (line 3)
ws.addRow(["X", "123", "XXX", "", "a", "", "", "", "", ""]);                                                // many errors (line 4)
ws.addRow(["Omar", "0501111111", "Abu Dhabi", "Nowhere", "Street 5", "", "", "", "", ""]);                  // unknown area (line 5)
ws.addRow(["Omar", "0501111111", "DXB", "Far Place", "Street 5", "", "", "", "", ""]);                       // area not covered (line 6)
ws.addRow(["Lina", "0502222222", "DXB", "", "Street 9", "", "prepaid", 50, "", ""]);                         // COD with prepaid (line 7)
ws.addRow(["Zed", "0503333333", "DXB", "", "Street 9", "", "", "", "", "OLD-9"]);                            // exists in DB (line 8)
ws.addRow(["Mona", "0504444444", "AUH", "", "Street 3", "", "", 99, "", "R-2"]);                             // ok, payment auto = cod (line 9)
ws.addRow([]);
const buf = Buffer.from(await wb.xlsx.writeBuffer());
const file = new File([buf], "t.xlsx");
const { table, error } = await readTable(file); assert.equal(error, undefined);
const { rows, error: e2 } = buildShipmentPreview(table!, emirates, areas, new Set(["old-9"])); assert.equal(e2, undefined);
const st = Object.fromEntries(rows.map((r) => [r.line, r.status]));
assert.deepEqual(st, { 2: "new", 3: "duplicate", 4: "error", 5: "error", 6: "error", 7: "error", 8: "duplicate", 9: "new" });
assert.equal(rows[0].parcel_count, 2); assert.equal(rows[0].service_type, "express"); assert.equal(rows[0].area_id, "a1");
assert.equal(rows.find((r) => r.line === 9)!.payment_method, "cod", "COD amount without payment => cod");
assert.equal(rows.find((r) => r.line === 3)!.payment_method, "prepaid", "no COD => prepaid");
assert.ok(rows.find((r) => r.line === 6)!.messages.join().includes("not covered"));
assert.ok(rows.find((r) => r.line === 4)!.messages.length >= 3);
// header problems and limits
assert.match(buildShipmentPreview([["name"], ["x"]], emirates, areas, new Set()).error!, /Missing column/);
assert.match(buildShipmentPreview([["recipient_name", "phone", "emirate", "address"], ...Array(501).fill(["a", "b", "c", "d"])], emirates, areas, new Set()).error!, /Max 500/);
// non-xlsx and empty uploads are refused
assert.ok((await readTable(new File(["x"], "a.csv"))).error);
assert.ok((await readTable(undefined)).error);
console.log("shipments-import: all assertions passed");
