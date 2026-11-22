import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
import { FinanceForms } from "./FinanceForms";

export const dynamic = "force-dynamic";

export default async function Finance() {
  const l = await getLocale();
  const supabase = await createClient();
  const [{ data: overview }, { data: recon }, { data: sessions }, { data: drivers }] = await Promise.all([
    supabase.rpc("finance_overview"),
    supabase.rpc("cod_reconciliation", { p_date: new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Dubai" }) }),
    supabase.from("driver_cash_sessions")
      .select("id,business_date,opening_balance,collected_cod,handed_over,expected_cash,counted_cash,difference,status,drivers(full_name)")
      .eq("status", "open").order("business_date", { ascending: false }).limit(50),
    supabase.from("drivers").select("id,full_name").eq("is_active", true).order("full_name"),
  ]);
  const o = (overview ?? {}) as any;
  const rows = (recon ?? []) as any[];
  const money = (v: any) => Number(v ?? 0).toFixed(2);

  const card = (label: string, value: any, tone = "text-slate-900") => (
    <div className="card"><div className="text-xs text-slate-500">{label}</div><div className={`mt-1 text-2xl font-bold ${tone}`} dir="ltr">{money(value)}</div></div>
  );

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">{tr(l, "finance")}</h1>
        <Link href="/finance/settlements" className="btn">{tr(l, "settlements")}</Link>
      </div>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        {card(tr(l, "collectedToday"), o.cod_collected_today, "text-emerald-700")}
        {card(tr(l, "codWithDrivers"), o.cod_with_drivers, "text-amber-700")}
        {card(tr(l, "revenueToday"), o.revenue_today)}
        {card(tr(l, "vat"), o.vat_today)}
        {card(tr(l, "merchantPayable"), o.merchant_payable_open)}
        {card(tr(l, "cashHandedToday"), o.cash_handed_today)}
        {card(tr(l, "expensesToday"), o.expenses_today, "text-rose-700")}
        {card(tr(l, "settlements") + " (" + tr(l, "under_review") + ")", o.settlements_in_progress)}
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="card overflow-x-auto p-0 lg:col-span-2">
          <h2 className="border-b px-4 py-3 text-sm font-semibold">{tr(l, "cod")} — {tr(l, "today")}</h2>
          <table className="w-full">
            <thead className="border-b bg-slate-50"><tr>
              <th className="th">{tr(l, "driver")}</th><th className="th">{tr(l, "collectedToday")}</th>
              <th className="th">{tr(l, "cashHandedToday")}</th><th className="th">{tr(l, "cashInHand")}</th>
            </tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.driver_id} className="border-b last:border-0">
                  <td className="td">{r.driver_name}</td>
                  <td className="td" dir="ltr">{money(r.collected)}</td>
                  <td className="td" dir="ltr">{money(r.handed)}</td>
                  <td className={`td font-medium ${Number(r.custody) > 0 ? "text-amber-700" : ""}`} dir="ltr">{money(r.custody)}</td>
                </tr>
              ))}
              {!rows.length && <tr><td colSpan={4} className="td text-center text-slate-500">{tr(l, "noData")}</td></tr>}
            </tbody>
          </table>
        </div>

        <FinanceForms sessions={(sessions ?? []).map((s: any) => ({
          id: s.id, business_date: s.business_date, opening_balance: Number(s.opening_balance),
          collected_cod: Number(s.collected_cod), handed_over: Number(s.handed_over),
          driver_name: s.drivers?.full_name ?? "",
        }))} t={{
          handover: tr(l, "handover"), driver: tr(l, "driver"), collectedAmount: tr(l, "collectedAmount"),
          reference: tr(l, "reference"), note: tr(l, "note"), save: tr(l, "save"), saving: tr(l, "saving"),
          closeSession: tr(l, "closeSession"), countedCash: tr(l, "countedCash"), difference: tr(l, "difference"),
          openSessions: tr(l, "openSessions"), date: tr(l, "date"), expectedCash: tr(l, "expectedCash"),
          collectedToday: tr(l, "collectedToday"), cashHandedToday: tr(l, "cashHandedToday"), noData: tr(l, "noData"),
          drivers: (drivers ?? []).map((d: any) => ({ id: d.id, name: d.full_name })),
        }} />
      </div>
    </div>
  );
}
