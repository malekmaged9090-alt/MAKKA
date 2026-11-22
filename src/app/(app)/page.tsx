import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
import { StatusBadge, type StatusRow } from "@/components/StatusBadge";

export const dynamic = "force-dynamic";

export default async function Dashboard() {
  const l = await getLocale();
  const supabase = await createClient();
  const today = new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Dubai" });
  const [{ data: statuses }, { data: rows }, { data: drivers }, { data: merchants }, { data: overview }] = await Promise.all([
    supabase.from("shipment_statuses").select("code,name_ar,name_en,color").order("sort_order"),
    supabase.from("shipments").select("status_code,cod_amount").gte("created_at", `${today}T00:00:00+04:00`),
    supabase.from("drivers").select("id,status").eq("is_active", true),
    supabase.from("merchants").select("id").eq("status", "active"),
    supabase.rpc("finance_overview"),
  ]);
  const counts: Record<string, number> = {};
  (rows ?? []).forEach((r: any) => { counts[r.status_code] = (counts[r.status_code] ?? 0) + 1; });
  const total = rows?.length ?? 0;
  const o = (overview ?? {}) as any;
  const money = (v: any) => Number(v ?? 0).toFixed(2);
  const activeDrivers = (drivers ?? []).filter((d: any) => !["offline", "suspended", "inactive"].includes(d.status)).length;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-bold">{tr(l, "dashboard")}</h1>
          <p className="text-xs text-slate-500" dir="ltr">{today} · Asia/Dubai</p>
        </div>
        <Link href="/shipments/new" className="btn">{tr(l, "newShipment")}</Link>
      </div>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <div className="card"><div className="text-xs text-slate-500">{tr(l, "todayOrders")}</div><div className="text-3xl font-bold">{total}</div></div>
        <div className="card"><div className="text-xs text-slate-500">{tr(l, "drivers")}</div><div className="text-3xl font-bold">{activeDrivers}<span className="text-sm font-normal text-slate-400"> / {drivers?.length ?? 0}</span></div></div>
        <div className="card"><div className="text-xs text-slate-500">{tr(l, "merchants")}</div><div className="text-3xl font-bold">{merchants?.length ?? 0}</div></div>
        <div className="card"><div className="text-xs text-slate-500">{tr(l, "collectedToday")}</div><div className="text-3xl font-bold text-emerald-700" dir="ltr">{money(o.cod_collected_today)}</div></div>
      </div>

      <div className="grid gap-3 md:grid-cols-4">
        {[
          [tr(l, "codWithDrivers"), o.cod_with_drivers, "text-amber-700"],
          [tr(l, "merchantPayable"), o.merchant_payable_open, "text-slate-900"],
          [tr(l, "revenueToday"), o.revenue_today, "text-emerald-700"],
          [tr(l, "expensesToday"), o.expenses_today, "text-rose-700"],
        ].map(([label, value, tone]: any) => (
          <div key={label} className="card py-3">
            <div className="text-[11px] text-slate-500">{label}</div>
            <div className={`text-lg font-semibold ${tone}`} dir="ltr">{money(value)}</div>
          </div>
        ))}
      </div>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
        {(statuses as StatusRow[] ?? []).filter((s) => counts[s.code]).map((s) => (
          <div key={s.code} className="card">
            <StatusBadge status={s} locale={l} />
            <div className="mt-2 text-2xl font-semibold">{counts[s.code]}</div>
          </div>
        ))}
        {total === 0 && <p className="text-sm text-slate-500">{tr(l, "noData")}</p>}
      </div>

      <div className="grid gap-3 md:grid-cols-3">
        {[["/dispatch", "dispatch"], ["/finance", "finance"], ["/finance/settlements", "settlements"]].map(([href, key]) => (
          <Link key={href} href={href} className="card flex items-center justify-between hover:border-emerald-400">
            <span className="text-sm font-medium">{tr(l, key)}</span><span className="text-slate-400">→</span>
          </Link>
        ))}
      </div>
    </div>
  );
}
