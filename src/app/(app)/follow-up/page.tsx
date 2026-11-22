import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";

export const dynamic = "force-dynamic";

export default async function FollowUpPage() {
  const l = await getLocale();
  const supabase = await createClient();
  const { data } = await supabase.from("shipments").select("id,serial_number,status_code,recipient_name,recipient_phone,expected_delivery_at,created_at,merchants(name),areas:delivery_area_id(name_ar,name_en)").in("status_code", ["ON_HOLD", "RESCHEDULED"]).order("updated_at", { ascending: false }).limit(500);
  const label = (x: any) => x?.[l === "ar" ? "name_ar" : "name_en"] ?? "-";
  return <div className="space-y-4"><div><h1 className="text-xl font-bold">{tr(l, "followUp")}</h1><p className="text-sm text-slate-500">{tr(l, "followUpHint")}</p></div><div className="card overflow-x-auto p-0"><table className="w-full"><thead><tr><th className="th">{tr(l, "serial")}</th><th className="th">{tr(l, "status")}</th><th className="th">{tr(l, "recipient")}</th><th className="th">{tr(l, "merchant")}</th><th className="th">{tr(l, "area")}</th><th className="th">{tr(l, "expectedDelivery")}</th><th className="th"></th></tr></thead><tbody>{(data ?? []).map((s: any) => <tr key={s.id}><td className="td font-mono" dir="ltr">{s.serial_number}</td><td className="td">{s.status_code === "ON_HOLD" ? tr(l, "onHold") : tr(l, "reschedule")}</td><td className="td">{s.recipient_name}<div className="text-xs text-slate-500" dir="ltr">{s.recipient_phone}</div></td><td className="td">{s.merchants?.name ?? "-"}</td><td className="td">{label(s.areas)}</td><td className="td text-xs" dir="ltr">{s.expected_delivery_at ? new Date(s.expected_delivery_at).toLocaleString("en-GB", { timeZone: "Asia/Dubai" }) : "-"}</td><td className="td"><Link className="text-emerald-700 underline" href={`/shipments/${s.id}`}>{tr(l, "view")}</Link></td></tr>)}{!data?.length && <tr><td colSpan={7} className="td text-slate-500">{tr(l, "noData")}</td></tr>}</tbody></table></div></div>;
}
