import { getLocale, tr } from "@/lib/i18n";
import { createClient } from "@/lib/supabase/server";
import { ReportForm } from "./ReportForm";

export const dynamic = "force-dynamic";

export default async function ReportsPage() {
  const l = await getLocale();
  const supabase = await createClient();
  const [{ data: emirates }, { data: areas }, { data: merchants }, { data: drivers }] = await Promise.all([
    supabase.from("emirates").select("id,name_ar,name_en").order("name_en"),
    supabase.from("areas").select("id,name_ar,name_en").eq("is_active", true).order("name_en"),
    supabase.from("merchants").select("id,name").eq("status", "active").order("name"),
    supabase.from("drivers").select("id,full_name").eq("is_active", true).order("full_name"),
  ]);
  const keys = [
    "reportType","allShipments","dailyShipments","deliveredReport","failedReport","returns","driverPerformance","merchantPerformance",
    "byEmirate","byArea","dailyCod","driverCash","merchantStatement","settlementsReport","financeReport","overdueReport",
    "attemptsReport","branchMovements","barcodeReprints","from","to","status","statusOptional","runReport","results","exportCsv",
    "emirate","area","merchant","driver","all",
  ];
  const t = Object.fromEntries(keys.map((k) => [k, tr(l, k)]));
  const options = [
    ...(emirates ?? []).map((x: any) => ({ id: `emirate:${x.id}`, label: l === "ar" ? x.name_ar : x.name_en })),
    ...(areas ?? []).map((x: any) => ({ id: `area:${x.id}`, label: l === "ar" ? x.name_ar : x.name_en })),
    ...(merchants ?? []).map((x: any) => ({ id: `merchant:${x.id}`, label: x.name })),
    ...(drivers ?? []).map((x: any) => ({ id: `driver:${x.id}`, label: x.full_name })),
  ];
  return <div className="space-y-4"><h1 className="text-xl font-bold">{tr(l, "reports")}</h1><p className="text-sm text-slate-500">{tr(l, "reportsHint")}</p><ReportForm t={t} options={options} /></div>;
}
