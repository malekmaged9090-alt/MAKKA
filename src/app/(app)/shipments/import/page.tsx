import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
import { ImportForm } from "./ImportForm";
export const dynamic = "force-dynamic";
export default async function ImportShipments() {
  const l = await getLocale();
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from("profiles").select("merchant_id").eq("id", user?.id ?? "").maybeSingle();
  const { data: merchants } = profile?.merchant_id ? { data: [] } : await supabase.from("merchants").select("id,name").eq("status", "active").order("name").limit(500);
  const keys = ["merchant", "preview", "import", "template", "created", "openList", "new", "duplicates", "errors", "recipient", "phone", "address", "status"];
  const t = Object.fromEntries(keys.map((k) => [k, tr(l, k === "new" ? "newRow" : k)]));
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">{tr(l, "importShipments")}</h1>
      <p className="text-sm text-slate-600">{tr(l, "importShipmentsHelp")}</p>
      <ImportForm merchants={merchants ?? []} fixedMerchant={!!profile?.merchant_id} t={t} />
    </div>
  );
}
