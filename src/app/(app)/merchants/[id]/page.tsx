import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr, nm } from "@/lib/i18n";

export const dynamic = "force-dynamic";

export default async function MerchantPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const l = await getLocale();
  const supabase = await createClient();
  const { data: m } = await supabase.from("merchants")
    .select("*, emirates:emirate_id(name_ar,name_en), areas:area_id(name_ar,name_en)").eq("id", id).maybeSingle();
  if (!m) notFound();

  const to = new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Dubai" });
  const from = new Date(Date.now() - 30 * 864e5).toLocaleDateString("en-CA", { timeZone: "Asia/Dubai" });
  const [{ data: statement }, { data: shipments }, { data: settlements }] = await Promise.all([
    supabase.rpc("merchant_statement", { p_merchant: id, p_from: from, p_to: to }),
    supabase.from("shipments").select("id,serial_number,status_code,cod_amount,created_at").eq("merchant_id", id).order("created_at", { ascending: false }).limit(10),
    supabase.from("merchant_settlements").select("id,settlement_no,net_payable,status,period_end").eq("merchant_id", id).order("created_at", { ascending: false }).limit(5),
  ]);
  const st = (statement ?? {}) as any;
  const money = (v: any) => Number(v ?? 0).toFixed(2);

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">{m.name}</h1>
        <Link href="/merchants" className="btn-light">{tr(l, "merchants")}</Link>
      </div>

      <div className="grid gap-4 md:grid-cols-3">
        <div className="card space-y-1 text-sm md:col-span-2">
          <div className="grid grid-cols-2 gap-2">
            <div><span className="text-slate-500">{tr(l, "tradeName")}: </span>{m.trade_name ?? "-"}</div>
            <div><span className="text-slate-500">{tr(l, "phone")}: </span><span dir="ltr">{m.phone ?? "-"}</span></div>
            <div><span className="text-slate-500">{tr(l, "emirate")}: </span>{nm(l, m.emirates)}</div>
            <div><span className="text-slate-500">{tr(l, "area")}: </span>{nm(l, m.areas)}</div>
            <div><span className="text-slate-500">COD fee %: </span>{money(m.cod_fee_percent)}</div>
            <div><span className="text-slate-500">{tr(l, "fees")}: </span>{money(m.delivery_fee)}</div>
          </div>
        </div>
        <div className="card space-y-1">
          <div className="text-xs text-slate-500">{tr(l, "balance")} (30d)</div>
          <div className="text-2xl font-bold" dir="ltr">{money(st.closing_balance)}</div>
          <div className="text-xs text-slate-500">{tr(l, "openingBalance")}: {money(st.opening_balance)}</div>
        </div>
      </div>

      <div className="card overflow-x-auto p-0">
        <h2 className="border-b px-4 py-3 text-sm font-semibold">{tr(l, "merchantStatement")} · {from} → {to}</h2>
        <table className="w-full">
          <thead className="border-b bg-slate-50"><tr>
            <th className="th">{tr(l, "date")}</th><th className="th">{tr(l, "description")}</th>
            <th className="th">{tr(l, "debit")}</th><th className="th">{tr(l, "credit")}</th>
          </tr></thead>
          <tbody>
            {(st.entries ?? []).map((e: any) => (
              <tr key={e.id} className="border-b last:border-0">
                <td className="td text-xs" dir="ltr">{e.date}</td>
                <td className="td text-xs">{e.description}</td>
                <td className="td text-rose-700" dir="ltr">{Number(e.debit) ? money(e.debit) : ""}</td>
                <td className="td text-emerald-700" dir="ltr">{Number(e.credit) ? money(e.credit) : ""}</td>
              </tr>
            ))}
            {!(st.entries ?? []).length && <tr><td colSpan={4} className="td text-center text-slate-500">{tr(l, "noData")}</td></tr>}
          </tbody>
        </table>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <div className="card overflow-x-auto p-0">
          <h2 className="border-b px-4 py-3 text-sm font-semibold">{tr(l, "shipments")}</h2>
          <table className="w-full"><tbody>
            {(shipments ?? []).map((s: any) => (
              <tr key={s.id} className="border-b last:border-0">
                <td className="td font-mono text-xs"><Link className="text-emerald-700 underline" href={`/shipments/${s.id}`}>{s.serial_number}</Link></td>
                <td className="td text-xs">{s.status_code}</td>
                <td className="td text-xs" dir="ltr">{money(s.cod_amount)}</td>
              </tr>
            ))}
            {!shipments?.length && <tr><td className="td text-center text-slate-500">{tr(l, "noData")}</td></tr>}
          </tbody></table>
        </div>
        <div className="card overflow-x-auto p-0">
          <h2 className="border-b px-4 py-3 text-sm font-semibold">{tr(l, "settlements")}</h2>
          <table className="w-full"><tbody>
            {(settlements ?? []).map((s: any) => (
              <tr key={s.id} className="border-b last:border-0">
                <td className="td font-mono text-xs"><Link className="text-emerald-700 underline" href={`/finance/settlements/${s.id}`}>{s.settlement_no}</Link></td>
                <td className="td text-xs">{tr(l, s.status)}</td>
                <td className="td text-xs" dir="ltr">{money(s.net_payable)}</td>
              </tr>
            ))}
            {!settlements?.length && <tr><td className="td text-center text-slate-500">{tr(l, "noSettlements")}</td></tr>}
          </tbody></table>
        </div>
      </div>
    </div>
  );
}
