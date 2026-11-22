"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type ReturnState = { error?: string; ok?: boolean; id?: string } | undefined;

function refresh(id?: string) {
  revalidatePath("/returns");
  if (id) revalidatePath(`/returns/${id}`);
}

export async function createReturn(_: ReturnState, fd: FormData): Promise<ReturnState> {
  const supabase = await createClient();
  const shipment = String(fd.get("shipment_id") ?? "");
  const { data, error } = await supabase.rpc("create_return", {
    p_shipment: shipment,
    p_reason_code: String(fd.get("reason_code") ?? "other"),
    p_note: String(fd.get("note") ?? "") || null,
    p_type: String(fd.get("return_type") ?? "customer_return"),
    p_branch: null,
  });
  if (error) return { error: error.message };
  revalidatePath(`/shipments/${shipment}`);
  refresh();
  return { ok: true, id: String(data) };
}

export async function receiveReturn(_: ReturnState, fd: FormData): Promise<ReturnState> {
  const supabase = await createClient();
  const id = String(fd.get("id"));
  const { error } = await supabase.rpc("receive_return", {
    p_return: id, p_branch: null, p_note: String(fd.get("note") ?? "") || null,
  });
  if (error) return { error: error.message };
  refresh(id);
  return { ok: true };
}

export async function inspectReturn(_: ReturnState, fd: FormData): Promise<ReturnState> {
  const supabase = await createClient();
  const id = String(fd.get("id"));
  const { error } = await supabase.rpc("inspect_return", {
    p_return: id, p_condition: String(fd.get("condition") ?? "good"), p_note: String(fd.get("note") ?? "") || null,
  });
  if (error) return { error: error.message };
  refresh(id);
  return { ok: true };
}

export async function completeReturn(_: ReturnState, fd: FormData): Promise<ReturnState> {
  const supabase = await createClient();
  const id = String(fd.get("id"));
  const { error } = await supabase.rpc("complete_return", { p_return: id });
  if (error) return { error: error.message };
  refresh(id);
  return { ok: true };
}

export async function cancelReturn(_: ReturnState, fd: FormData): Promise<ReturnState> {
  const supabase = await createClient();
  const id = String(fd.get("id"));
  const { error } = await supabase.rpc("cancel_return", {
    p_return: id, p_reason: String(fd.get("reason") ?? ""),
  });
  if (error) return { error: error.message };
  refresh(id);
  return { ok: true };
}
