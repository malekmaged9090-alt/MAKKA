"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function assignSelected(_: { error?: string; ok?: string } | undefined, fd: FormData) {
  const driverId = String(fd.get("driver_id") ?? "");
  const ids = fd.getAll("ids").map(String).filter(Boolean);
  if (!driverId) return { error: "Driver is required" };
  if (!ids.length) return { error: "Select at least one shipment" };
  const supabase = await createClient();
  const { error } = await supabase.rpc("assign_shipments", { p_driver: driverId, p_shipments: ids });
  if (error) return { error: error.message };
  revalidatePath("/dispatch");
  return { ok: `${ids.length} shipment(s) assigned` };
}

export async function autoDispatchAll(_: { error?: string; ok?: string } | undefined, fd: FormData) {
  const ids = fd.getAll("ids").map(String).filter(Boolean);
  const supabase = await createClient();
  let list = ids;
  if (!list.length) {
    const { data } = await supabase.from("shipments").select("id").eq("status_code", "READY_FOR_DISPATCH").limit(500);
    list = (data ?? []).map((r: any) => r.id);
  }
  if (!list.length) return { error: "No shipments ready for dispatch" };
  const { data, error } = await supabase.rpc("auto_dispatch", { p_shipments: list });
  if (error) return { error: error.message };
  revalidatePath("/dispatch");
  return { ok: `${data ?? 0} shipment(s) auto-assigned` };
}

export async function closeManifest(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("close_manifest", { p_manifest: String(fd.get("id")) });
  revalidatePath("/dispatch");
  if (error) redirect(`/dispatch?error=${encodeURIComponent(error.message)}`);
  redirect("/dispatch?ok=closed");
}

export async function reassignFromDispatch(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("reassign_shipment_ext", {
    p_shipment: String(fd.get("shipment_id")),
    p_driver: String(fd.get("driver_id")),
    p_reason: String(fd.get("reason") ?? ""),
  });
  revalidatePath("/dispatch");
  if (error) redirect(`/dispatch?error=${encodeURIComponent(error.message)}`);
  redirect("/dispatch?ok=reassigned");
}
