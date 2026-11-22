import ExcelJS from "exceljs";
import { requirePermission } from "@/lib/auth";
export const dynamic = "force-dynamic";
export async function GET() {
  const g = await requirePermission("geo.manage");
  if (!g.ok) return new Response(g.error, { status: 403 });
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet("areas");
  ws.addRow(["emirate", "name_en", "name_ar", "zone", "needs_review"]);
  ws.addRow(["DXB", "Example Area", "منطقة مثال", "", ""]); // sample row: delete before importing real data
  ws.getRow(1).font = { bold: true };
  ws.columns.forEach((c) => (c.width = 22));
  const buf = await wb.xlsx.writeBuffer();
  return new Response(buf as ArrayBuffer, { headers: {
    "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "Content-Disposition": 'attachment; filename="areas-template.xlsx"' } });
}
