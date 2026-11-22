import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
import { NewDriverForm } from "./NewDriverForm";

export const dynamic = "force-dynamic";

export default async function NewDriver() {
  const l = await getLocale();
  const supabase = await createClient();
  const [{ data: emirates }, { data: areas }] = await Promise.all([
    supabase.from("emirates").select("id,name_ar,name_en").order("name_en"),
    supabase.from("areas").select("id,emirate_id,name_ar,name_en").eq("is_active", true).order("name_en"),
  ]);
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">{tr(l, "newDriver")}</h1>
      <NewDriverForm locale={l} emirates={emirates ?? []} areas={areas ?? []} t={{
        name: tr(l, "name"), phone: tr(l, "phone"), email: tr(l, "email"), emirate: tr(l, "emirate"),
        area: tr(l, "area"), save: tr(l, "save"), saving: tr(l, "saving"), employeeNo: tr(l, "employeeNo"),
        hiredOn: tr(l, "hiredOn"), contractType: tr(l, "contractType"), licenseExpiry: tr(l, "licenseExpiry"),
        vehicle: tr(l, "vehicle"), plate: tr(l, "plate"), commission: tr(l, "commission"),
      }} />
    </div>
  );
}
