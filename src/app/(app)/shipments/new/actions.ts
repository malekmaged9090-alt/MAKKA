"use server";
import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

const money = z.coerce.number().min(0).max(9_999_999.99);
const schema = z.object({
  idempotency_key: z.string().uuid(),
  merchant_id: z.string().uuid().optional().or(z.literal("")),
  merchant_reference: z.string().trim().max(100).optional(),
  recipient_name: z.string().trim().min(2).max(150),
  recipient_phone: z.string().trim().regex(/^[+0-9 ()-]{7,20}$/, "Invalid phone"),
  emirate_id: z.string().uuid(),
  area_id: z.string().uuid().optional().or(z.literal("")),
  address: z.string().trim().min(3).max(500),
  service_type: z.enum(["same_day", "next_day", "standard", "express", "scheduled", "return_pickup", "exchange", "document"]),
  parcel_count: z.coerce.number().int().min(1).max(99),
  weight_kg: z.coerce.number().min(0).max(9999).optional().or(z.literal("")),
  description: z.string().trim().max(500).optional(),
  goods_value: money,
  payment_method: z.enum(["cash", "card", "online_paid", "prepaid", "cod"]),
  cod_amount: money,
  notes: z.string().trim().max(1000).optional(),
}).refine((v) => v.payment_method === "cod" || v.cod_amount === 0, { message: "COD amount must be 0 unless payment method is COD", path: ["cod_amount"] });

export async function createShipment(_: { error?: string } | undefined, fd: FormData) {
  const parsed = schema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { error: parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join(" | ") };
  const v = parsed.data;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Not signed in" };

  const { data: profile } = await supabase.from("profiles").select("company_id,merchant_id").eq("id", user.id).single();
  if (!profile) return { error: "Profile not found" };
  const merchantId = profile.merchant_id ?? (v.merchant_id || null);
  if (!merchantId) return { error: "Merchant is required" };

  // Link to an existing customer only on exact phone + name match; never auto-merge otherwise.
  let customerId: string | null = null;
  const { data: found } = await supabase.from("customers").select("id,full_name").eq("phone", v.recipient_phone).limit(20);
  const hit = found?.find((c) => c.full_name.trim().toLowerCase() === v.recipient_name.toLowerCase());
  if (hit) customerId = hit.id;
  else {
    const { data: c } = await supabase.from("customers")
      .insert({ company_id: profile.company_id, full_name: v.recipient_name, phone: v.recipient_phone, created_by: user.id })
      .select("id").single();
    customerId = c?.id ?? null; // may be null if the role cannot manage customers; shipment keeps its own snapshot
  }

  const { data, error } = await supabase.from("shipments").insert({
    company_id: profile.company_id, merchant_id: merchantId, merchant_reference: v.merchant_reference || null,
    idempotency_key: v.idempotency_key, customer_id: customerId,
    recipient_name: v.recipient_name, recipient_phone: v.recipient_phone,
    delivery_emirate_id: v.emirate_id, delivery_area_id: v.area_id || null, delivery_address_text: v.address,
    service_type: v.service_type, parcel_count: v.parcel_count, weight_kg: v.weight_kg === "" ? null : v.weight_kg,
    description: v.description || null, goods_value: v.goods_value, payment_method: v.payment_method,
    cod_amount: v.cod_amount, notes: v.notes || null, created_by: user.id,
    // serial_number / tracking_number / tracking_token / status are assigned by the database
    serial_number: "pending", tracking_number: "pending", tracking_token: "pending",
  }).select("id").single();

  if (error) {
    if (error.code === "23505" && error.message.includes("idempotency")) {   // double submit -> open the first one
      const { data: ex } = await supabase.from("shipments").select("id").eq("idempotency_key", v.idempotency_key).single();
      if (ex) redirect(`/shipments/${ex.id}`);
    }
    return { error: error.message };
  }
  redirect(`/shipments/${data.id}`);
}
