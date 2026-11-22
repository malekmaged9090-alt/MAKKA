import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr, nm } from "@/lib/i18n";

export const dynamic = "force-dynamic";

const STATUS_COLOR: Record<string, string> = {
  available: "bg-emerald-100 text-emerald-800",
  busy: "bg-amber-100 text-amber-800",
  on_delivery: "bg-blue-100 text-blue-800",
  offline: "bg-slate-100 text-slate-600",
  on_break: "bg-yellow-100 text-yellow-800",
  suspended: "bg-rose-100 text-rose-800",
  inactive: "bg-slate-200 text-slate-500",
};

export default async function Drivers() {
  const l = await getLocale();
  const supabase = await createClient();
  const [{ data: drivers }, { data: loads }] = await Promise.all([
    supabase.from("drivers")
      .select("id,driver_no,full_name,phone,status,is_active,commission_per_delivery,emirates:emirate_id(name_ar,name_en),driver_area_assignments(areas:area_id(name_ar,name_en))")
      .order("driver_no", { ascending: false }).limit(200),
    supabase.from("shipment_assignments").select("driver_id").eq("is_current", true),
  ]);
  const load = new Map<string, number>();
  (loads ?? []).forEach((r: any) => load.set(r.driver_id, (load.get(r.driver_id) ?? 0) + 1));

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">{tr(l, "drivers")}</h1>
        <Link href="/drivers/new" className="btn">{tr(l, "newDriver")}</Link>
      </div>
      <div className="card overflow-x-auto p-0">
        <table className="w-full">
          <thead className="border-b bg-slate-50"><tr>
            {["driverNo", "name", "phone", "emirate", "coverage", "status", "load", "commission"].map((k) => <th key={k} className="th">{tr(l, k)}</th>)}
          </tr></thead>
          <tbody>
            {(drivers ?? []).map((d: any) => (
              <tr key={d.id} className="border-b last:border-0 hover:bg-slate-50">
                <td className="td font-mono">{d.driver_no}</td>
                <td className="td font-medium">{d.full_name}</td>
                <td className="td" dir="ltr">{d.phone}</td>
                <td className="td">{nm(l, d.emirates)}</td>
                <td className="td text-xs text-slate-600">
                  {(d.driver_area_assignments ?? []).map((a: any) => nm(l, a.areas)).filter(Boolean).join("، ") || "-"}
                </td>
                <td className="td">
                  <span className={`rounded px-2 py-0.5 text-xs ${STATUS_COLOR[d.status] ?? "bg-slate-100"}`}>{tr(l, d.status)}</span>
                </td>
                <td className="td">{load.get(d.id) ?? 0}</td>
                <td className="td" dir="ltr">{Number(d.commission_per_delivery ?? 0).toFixed(2)}</td>
              </tr>
            ))}
            {!drivers?.length && <tr><td colSpan={8} className="td text-center text-slate-500">{tr(l, "noDrivers")}</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
