"use server";
import { createClient } from "@/lib/supabase/server";

export type ReportState = { error?: string; rows?: any[] } | undefined;

export async function loadReport(_: ReportState, fd: FormData): Promise<ReportState> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_rows", {
    p_report: String(fd.get("report") ?? "all_shipments"),
    p_from: String(fd.get("from") ?? "") || null,
    p_to: String(fd.get("to") ?? "") || null,
    p_status: String(fd.get("status") ?? "") || null,
    p_emirate: String(fd.get("emirate") ?? "") || null,
    p_area: String(fd.get("area") ?? "") || null,
    p_merchant: String(fd.get("merchant") ?? "") || null,
    p_driver: String(fd.get("driver") ?? "") || null,
  });
  if (error) return { error: error.message };
  return { rows: Array.isArray(data) ? data : [data] };
}
