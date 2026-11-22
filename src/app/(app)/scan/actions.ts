"use server";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function scanLookup(_: { error?: string } | undefined, fd: FormData) {
  const raw = String(fd.get("code") ?? "").trim().toUpperCase();
  if (!raw) return { error: "empty" };
  const base = raw.replace(/-P\d{2}$/, "");                     // parcel serial -> shipment serial
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: s } = await supabase.from("shipments").select("id")
    .or(`serial_number.eq.${base.replace(/[,()]/g, "")},tracking_number.eq.${base.replace(/[,()]/g, "")}`).maybeSingle();
  await supabase.from("shipment_scans").insert({ shipment_id: s?.id ?? null, scanned_code: raw, scan_context: "lookup", scanned_by: user?.id });
  if (!s) return { error: "notFound" };
  redirect(`/shipments/${s.id}`);
}

export type BulkState = { error?: string; data?: any } | undefined;

export async function bulkScan(_: BulkState, fd: FormData): Promise<BulkState> {
  const codes = String(fd.get("codes") ?? "")
    .split(/\r?\n|,|;/).map((x) => x.trim()).filter(Boolean).slice(0, 500);
  if (!codes.length) return { error: "empty" };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("bulk_scan", {
    p_codes: codes,
    p_scan_type: String(fd.get("scan_type") ?? "receive_at_hub"),
    p_branch: null,
    p_driver: null,
    p_note: String(fd.get("note") ?? "") || null,
  });
  if (error) return { error: error.message };
  return { data };
}
