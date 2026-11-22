import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
import { NewSettlement, SettlementActions } from "./SettlementForms";

export const dynamic = "force-dynamic";

const TONE: Record<string, string> = {
  draft: "bg-slate-100 text-slate-700",
  under_review: "bg-amber-100 text-amber-800",
  approved: "bg-blue-100 text-blue-800",
  paid: "bg-emerald-100 text-emerald-800",
  cancelled: "bg-rose-100 text-rose-800",
};

export default async function Settlements() {
  const l = await getLocale();
  const supabase = await createClient();
  const today = new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Dubai" });
  const weekAgo = new Date(Date.now() - 7 * 864e5).toLocaleDateString("en-CA", { timeZone: "Asia/Dubai" });
  const [{ data: rows }, { data: merchants }] = await Promise.all([
    supabase.from("merchant_settlements")
      .select("id,settlement_no,period_start,period_end,shipments_count,cod_total,net_payable,status,merchants(name)")
      .order("created_at", { ascending: false }).limit(100),
    supabase.from("merchants").select("id,name").order("name"),
  ]);

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">{tr(l, "settlements")}</h1>
        <Link href="/finance" className="btn-light">{tr(l, "finance")}</Link>
      </div>

      <NewSettlement merchants={(merchants ?? []) as any} today={today} weekAgo={weekAgo} t={{
        merchant: tr(l, "merchant"), periodFrom: tr(l, "periodFrom"), periodTo: tr(l, "periodTo"),
        createSettlement: tr(l, "createSettlement"), newSettlementHint: tr(l, "newSettlementHint"),
      }} />

      <div className="card overflow-x-auto p-0">
        <table className="w-full">
          <thead className="border-b bg-slate-50"><tr>
            {["#", "merchant", "periodFrom", "parcels", "cod", "fees", "netPayable", "status", "actions"].map((k) => <th key={k} className="th">{tr(l, k)}</th>)}
          </tr></thead>
          <tbody>
            {(rows ?? []).map((s: any) => (
              <tr key={s.id} className="border-b last:border-0 hover:bg-slate-50">
                <td className="td font-mono text-xs"><Link className="text-emerald-700 underline" href={`/finance/settlements/${s.id}`}>{s.settlement_no}</Link></td>
                <td className="td">{s.merchants?.name}</td>
                <td className="td text-xs" dir="ltr">{s.period_start} → {s.period_end}</td>
                <td className="td">{s.shipments_count}</td>
                <td className="td" dir="ltr">{Number(s.cod_total).toFixed(2)}</td>
                <td className="td" dir="ltr">{(Number(s.cod_total) - Number(s.net_payable)).toFixed(2)}</td>
                <td className="td font-medium" dir="ltr">{Number(s.net_payable).toFixed(2)}</td>
                <td className="td"><span className={`rounded px-2 py-0.5 text-[11px] ${TONE[s.status]}`}>{tr(l, s.status)}</span></td>
                <td className="td"><SettlementActions id={s.id} status={s.status} t={{
                  submit: tr(l, "submit"), approve: tr(l, "approve"), pay: tr(l, "pay"), invoice: tr(l, "invoice"),
                }} /></td>
              </tr>
            ))}
            {!rows?.length && <tr><td colSpan={9} className="td py-8 text-center text-slate-500">{tr(l, "noSettlements")}</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
