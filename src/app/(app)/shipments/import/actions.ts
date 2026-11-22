"use server";
import { createHash } from "node:crypto";
import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/auth";
import { readTable } from "@/lib/xlsx";
import { buildShipmentPreview, mapHeaders, type ShipRow } from "@/lib/shipments-import";
export type ImportState = { rows?: ShipRow[]; error?: string; done?: { inserted: number } };

// Deterministic UUID per (file, merchant, line): re-submitting the same file can never create duplicates.
const keyFor = (batch: string, line: number) => {
  const b = createHash("sha256").update(`${batch}:${line}`).digest().subarray(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50; b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString("hex"); return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
};

async function run(mode: "preview" | "commit", fd: FormData): Promise<ImportState> {
  const g = await requirePermission("shipments.create");
  if (!g.ok) return { error: g.error };
  const merchantId = g.merchantId ?? (String(fd.get("merchant_id") ?? "") || null);
  if (!merchantId) return { error: "اختر التاجر / Choose a merchant" };
  const { table, bytes, error } = await readTable(fd.get("file"));
  if (error || !table || !bytes) return { error };
  const [{ data: emirates }, { data: areas }] = await Promise.all([
    g.supabase.from("emirates").select("id,code,name_en,name_ar"),
    g.supabase.from("areas").select("id,emirate_id,name_en,name_ar,is_covered,is_active").limit(5000),
  ]);
  // existing merchant references (checked in chunks) so a re-uploaded sheet cannot duplicate orders
  const refCol = mapHeaders(table[0]).merchant_reference ?? -1;
  const refs = refCol < 0 ? [] : [...new Set(table.slice(1).map((r) => (r[refCol] ?? "").trim()).filter(Boolean))];
  const existing = new Set<string>();
  for (let i = 0; i < refs.length; i += 150) {
    const { data } = await g.supabase.from("shipments").select("merchant_reference").eq("merchant_id", merchantId).in("merchant_reference", refs.slice(i, i + 150));
    (data ?? []).forEach((s) => s.merchant_reference && existing.add(String(s.merchant_reference).toLowerCase()));
  }
  const { rows, error: perr } = buildShipmentPreview(table, emirates ?? [], areas ?? [], existing);
  if (perr) return { error: perr };
  if (mode === "preview") return { rows };

  if (rows.some((r) => r.status === "error")) return { rows, error: "أصلح الأخطاء أولاً / Fix the errors first" };
  const fresh = rows.filter((r) => r.status === "new");
  if (!fresh.length) return { rows, error: "لا توجد صفوف جديدة / No new rows to import" };

  // customers: link on exact phone + name, otherwise create (best effort; shipments keep their own snapshot)
  const phones = [...new Set(fresh.map((r) => r.recipient_phone))];
  const known = new Map<string, string>();
  for (let i = 0; i < phones.length; i += 150) {
    const { data } = await g.supabase.from("customers").select("id,full_name,phone").in("phone", phones.slice(i, i + 150));
    (data ?? []).forEach((c) => known.set(`${c.phone}|${c.full_name.trim().toLowerCase()}`, c.id));
  }
  const missing = new Map<string, { company_id: string; full_name: string; phone: string; created_by: string }>();
  for (const r of fresh) { const k = `${r.recipient_phone}|${r.recipient_name.toLowerCase()}`; if (!known.has(k) && !missing.has(k)) missing.set(k, { company_id: g.companyId, full_name: r.recipient_name, phone: r.recipient_phone, created_by: g.user.id }); }
  if (missing.size) {
    const { data } = await g.supabase.from("customers").insert([...missing.values()]).select("id,full_name,phone");
    (data ?? []).forEach((c) => known.set(`${c.phone}|${c.full_name.trim().toLowerCase()}`, c.id));
  }
  const batch = createHash("sha256").update(Buffer.from(bytes)).update(`|${g.companyId}|${merchantId}`).digest("hex");
  // ONE insert statement = atomic: all rows or none
  const { error: ierr } = await g.supabase.from("shipments").insert(fresh.map((r) => ({
    company_id: g.companyId, merchant_id: merchantId, merchant_reference: r.merchant_reference || null, idempotency_key: keyFor(batch, r.line),
    customer_id: known.get(`${r.recipient_phone}|${r.recipient_name.toLowerCase()}`) ?? null,
    recipient_name: r.recipient_name, recipient_phone: r.recipient_phone, delivery_emirate_id: r.emirate_id, delivery_area_id: r.area_id, delivery_address_text: r.address,
    service_type: r.service_type, parcel_count: r.parcel_count, weight_kg: r.weight_kg, description: r.description || null, goods_value: r.goods_value,
    payment_method: r.payment_method, cod_amount: r.cod_amount, notes: r.notes || null, created_by: g.user.id,
    serial_number: "pending", tracking_number: "pending", tracking_token: "pending",
  })));
  if (ierr) return { rows, error: ierr.code === "23505" && ierr.message.includes("idempotency") ? "هذا الملف استُورد من قبل / This file was already imported" : ierr.message };
  revalidatePath("/shipments");
  return { rows, done: { inserted: fresh.length } };
}
export async function previewShipments(_: ImportState | undefined, fd: FormData) { return run("preview", fd); }
export async function commitShipments(_: ImportState | undefined, fd: FormData) { return run("commit", fd); }
