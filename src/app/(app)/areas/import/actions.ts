"use server";
import ExcelJS from "exceljs";
import { z } from "zod";
import type { SupabaseClient } from "@supabase/supabase-js";
import { requirePermission } from "@/lib/auth";
import { buildPreview, norm, type ImportRow } from "@/lib/areas-import";

export type PreviewState = { rows?: ImportRow[]; error?: string; done?: { inserted: number } };

const cellText = (v: ExcelJS.CellValue): string => {
  if (v == null) return "";
  if (typeof v === "object") {
    if ("richText" in v) return v.richText.map((t) => t.text).join("");
    if ("text" in v) return String((v as { text: unknown }).text ?? "");
    if ("result" in v) return String((v as { result: unknown }).result ?? "");
    return "";
  }
  return String(v);
};

async function loadExisting(supabase: SupabaseClient) {
  const { data } = await supabase.from("areas").select("emirate_id,name_en").limit(20000);
  return new Set((data ?? []).map((a) => `${a.emirate_id}|${norm(a.name_en)}`));
}

export async function previewAreas(_: PreviewState | undefined, fd: FormData): Promise<PreviewState> {
  const g = await requirePermission("geo.manage");
  if (!g.ok) return { error: g.error };
  const file = fd.get("file");
  if (!(file instanceof File) || file.size === 0) return { error: "اختر ملف .xlsx / Choose an .xlsx file" };
  if (!file.name.toLowerCase().endsWith(".xlsx")) return { error: "الصيغة المدعومة .xlsx فقط / Only .xlsx supported" };
  if (file.size > 4 * 1024 * 1024) return { error: "الملف أكبر من 4MB / File over 4MB" };
  const wb = new ExcelJS.Workbook();
  try { await wb.xlsx.load(await file.arrayBuffer() as ExcelJS.Buffer); } catch { return { error: "تعذّر قراءة الملف / Could not read file" }; }
  const ws = wb.worksheets[0];
  if (!ws) return { error: "لا توجد أوراق / No sheets" };
  const table: string[][] = [];
  ws.eachRow({ includeEmpty: false }, (row) => {
    const cells: string[] = [];
    for (let c = 1; c <= Math.min(ws.columnCount, 20); c++) cells.push(cellText(row.getCell(c).value).trim());
    table.push(cells);
  });
  const { data: emirates } = await g.supabase.from("emirates").select("id,code,name_en,name_ar");
  const existing = await loadExisting(g.supabase);
  return buildPreview(table, emirates ?? [], existing);
}

const rowSchema = z.object({
  line: z.number().int(), emirate_id: z.string().uuid(), name_en: z.string().trim().min(1).max(150),
  name_ar: z.string().trim().min(1).max(150), zone: z.string().trim().max(150), needs_review: z.boolean(),
});

export async function commitAreas(_: PreviewState | undefined, fd: FormData): Promise<PreviewState> {
  const g = await requirePermission("geo.manage");
  if (!g.ok) return { error: g.error };
  let parsed: z.infer<typeof rowSchema>[];
  try {
    parsed = z.array(rowSchema).min(1).max(2000).parse(JSON.parse(String(fd.get("rows") ?? "[]")));
  } catch { return { error: "بيانات غير صالحة / Invalid data" }; }

  // Re-check against the DB (the preview may be stale) and against duplicates inside the payload.
  const existing = await loadExisting(g.supabase);
  const seen = new Set<string>();
  const fresh = parsed.filter((r) => {
    const k = `${r.emirate_id}|${norm(r.name_en)}`;
    if (existing.has(k) || seen.has(k)) return false;
    seen.add(k); return true;
  });
  if (!fresh.length) return { error: "لا توجد صفوف جديدة / No new rows" };

  const zoneNames = [...new Set(fresh.map((r) => r.zone).filter(Boolean))];
  const zoneIds = new Map<string, string>();
  if (zoneNames.length) {
    const { data, error } = await g.supabase.from("service_zones")
      .upsert(zoneNames.map((name) => ({ company_id: g.companyId, name })), { onConflict: "company_id,name" }).select("id,name");
    if (error) return { error: error.message };
    (data ?? []).forEach((z) => zoneIds.set(z.name, z.id));
  }
  // One INSERT statement = atomic: either all rows are added or none.
  const { error } = await g.supabase.from("areas").insert(fresh.map((r) => ({
    emirate_id: r.emirate_id, name_en: r.name_en, name_ar: r.name_ar,
    service_zone_id: r.zone ? zoneIds.get(r.zone) ?? null : null, needs_review: r.needs_review,
  })));
  if (error) return { error: error.message };
  return { done: { inserted: fresh.length } };
}
