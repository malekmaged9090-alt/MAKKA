import ExcelJS from "exceljs";
import assert from "node:assert/strict";
import { buildPreview, norm } from "../../src/lib/areas-import";

const emirates = [
  { id: "00000000-0000-0000-0000-00000000000a", code: "DXB", name_en: "Dubai", name_ar: "دبي" },
  { id: "00000000-0000-0000-0000-00000000000b", code: "AUH", name_en: "Abu Dhabi", name_ar: "أبوظبي" },
];
const wb = new ExcelJS.Workbook(); const ws = wb.addWorksheet("a");
ws.addRow(["Emirate", "Name_EN", "الاسم العربي", "Zone"]);
ws.addRow(["DXB", "Deira", "ديرة", "Z1"]);
ws.addRow(["Dubai", "deira ", "ديره", ""]);          // duplicate of line 2 (case/space)
ws.addRow(["أبوظبي", "Mezaira'a/Mirfa", "المزيرعة", ""]); // compound -> review
ws.addRow(["XXX", "Nowhere", "لا مكان", ""]);        // unknown emirate
ws.addRow(["AUH", "Al Bateen", "", ""]);             // missing arabic
ws.addRow(["AUH", "Al Khabisi", "المزيرعة", ""]);    // same Arabic as line 4 -> review both
ws.addRow(["DXB", "Existing One", "موجود", ""]);     // exists
ws.addRow([]);                                       // blank
const buf = await wb.xlsx.writeBuffer();
const wb2 = new ExcelJS.Workbook(); await wb2.xlsx.load(buf as ExcelJS.Buffer);
const table: string[][] = [];
wb2.worksheets[0].eachRow({ includeEmpty: false }, (r) => table.push([1, 2, 3, 4].map((c) => String(r.getCell(c).value ?? ""))));

const existing = new Set([`${emirates[0].id}|${norm("Existing One")}`]);
const { rows, error } = buildPreview(table, emirates, existing);
assert.equal(error, undefined);
const st = Object.fromEntries(rows.map((r) => [r.line, r.status]));
assert.deepEqual(st, { 2: "new", 3: "duplicate", 4: "new", 5: "error", 6: "error", 7: "new", 8: "exists" });
assert.equal(rows[0].needs_review, true, "first of a duplicate pair flagged");
assert.equal(rows.find((r) => r.line === 4)!.needs_review, true, "compound name flagged");
assert.equal(rows.find((r) => r.line === 7)!.needs_review, true, "same Arabic name flagged");
assert.equal(rows.find((r) => r.line === 4)!.emirate_id, emirates[1].id, "Arabic emirate name resolved");
assert.equal(buildPreview([["emirate", "name_en"]], emirates, new Set()).error !== undefined, true);
assert.match(buildPreview([["emirate", "name_en", "x"], ["DXB", "a", "b"]], emirates, new Set()).error!, /name_ar/);
console.log("areas-import: all assertions passed");
