"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

const uuid = () => crypto.randomUUID();

export async function handoverCash(_: { error?: string; ok?: string } | undefined, fd: FormData) {
  const driver = String(fd.get("driver_id") ?? "");
  const amount = Number(fd.get("amount") ?? 0);
  if (!driver || amount <= 0) return { error: "Driver and a positive amount are required" };
  const supabase = await createClient();
  const { error } = await supabase.rpc("record_cash_handover", {
    p_driver: driver, p_amount: amount,
    p_reference: String(fd.get("reference") ?? "") || null,
    p_note: String(fd.get("note") ?? "") || null,
    p_idempotency_key: uuid(),
  });
  if (error) return { error: error.message };
  revalidatePath("/finance");
  return { ok: `Handover of ${amount.toFixed(2)} AED recorded` };
}

export async function closeSession(_: { error?: string; ok?: string } | undefined, fd: FormData) {
  const session = String(fd.get("session_id") ?? "");
  const counted = Number(fd.get("counted") ?? 0);
  const note = String(fd.get("note") ?? "");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("close_driver_cash_session", {
    p_session: session, p_counted: counted, p_note: note || null,
  });
  if (error) return { error: error.message };
  revalidatePath("/finance");
  return { ok: `Session closed, difference ${Number(data ?? 0).toFixed(2)} AED` };
}

export async function createSettlement(_: { error?: string; ok?: string } | undefined, fd: FormData) {
  const merchant = String(fd.get("merchant_id") ?? "");
  const from = String(fd.get("from") ?? "");
  const to = String(fd.get("to") ?? "");
  if (!merchant || !from || !to) return { error: "Merchant and period are required" };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_merchant_settlement", {
    p_merchant: merchant, p_from: from, p_to: to, p_note: null, p_idempotency_key: uuid(),
  });
  if (error) return { error: error.message };
  revalidatePath("/finance/settlements");
  return { ok: `Settlement created (${data})` };
}

export async function settlementAction(_: { error?: string; ok?: string } | undefined, fd: FormData) {
  const id = String(fd.get("id") ?? "");
  const op = String(fd.get("op") ?? "");
  const supabase = await createClient();
  let error: any = null;
  if (op === "submit") ({ error } = await supabase.rpc("submit_merchant_settlement", { p_settlement: id }));
  else if (op === "approve") ({ error } = await supabase.rpc("approve_merchant_settlement", { p_settlement: id }));
  else if (op === "pay") ({ error } = await supabase.rpc("pay_merchant_settlement", {
    p_settlement: id, p_method: String(fd.get("method") ?? "bank"), p_reference: null, p_idempotency_key: uuid(),
  }));
  else if (op === "invoice") ({ error } = await supabase.rpc("create_invoice_from_settlement", { p_settlement: id }));
  else return { error: "Unknown action" };
  if (error) return { error: error.message };
  revalidatePath("/finance/settlements");
  revalidatePath(`/finance/settlements/${id}`);
  return { ok: "Done" };
}
