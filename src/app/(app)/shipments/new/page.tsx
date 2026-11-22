import { randomUUID } from "crypto";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
import { NewShipmentForm } from "./NewShipmentForm";

export const dynamic = "force-dynamic";
export default async function NewShipment() {
  const l = await getLocale();
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from("profiles").select("merchant_id").eq("id", user!.id).single();
  const [{ data: merchants }, { data: emirates }, { data: areas }] = await Promise.all([
    profile?.merchant_id ? Promise.resolve({ data: null }) : supabase.from("merchants").select("id,name").eq("status", "active").order("name"),
    supabase.from("emirates").select("id,name_ar,name_en").eq("is_active", true).order("sort_order"),
    supabase.from("areas").select("id,name_ar,name_en,emirate_id").eq("is_active", true).eq("is_covered", true).order("name_en"),
  ]);
  const keys = ["merchant", "merchantRef", "recipient", "phone", "emirate", "area", "address", "service", "parcels", "weight", "goodsValue", "payment", "description", "notes", "save", "saving"];
  const t = Object.fromEntries(keys.map((k) => [k, tr(l, k)]));
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">{tr(l, "newShipment")}</h1>
      {/* a fresh idempotency key per page load: re-submitting the same form can never create a 2nd shipment */}
      <NewShipmentForm locale={l} idemKey={randomUUID()} merchants={merchants as any} emirates={emirates ?? []} areas={(areas as any) ?? []} t={t} />
    </div>
  );
}
