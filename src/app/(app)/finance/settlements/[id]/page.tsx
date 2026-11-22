import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
import { SettlementActions } from "../SettlementForms";
import { PrintButton } from "./PrintButton";

export const dynamic = "force-dynamic";

export default async function SettlementPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const l = await getLocale();
  const supabase = await createClient();
  const { data: s } = await supabase.from("merchant_settlements")
    .select("*, merchants(name,trade_name,phone,email), companies(name_ar,name_en,trn)")
    .eq("id", id).maybeSingle();
  if (!s) notFound();
  const [{ data: lines }, { data: invoice }] = await Promise.all([
    supabase.from("settlement_lines").select("id,entry_type,description,amount,shipment_id,shipments(serial_number)").eq("settlement_id", id).order("created_at"),
    supabase.from("invoices").select("id,invoice_no,total,status").eq("settlement_id", id).maybeSingle(),
  ]);
  const money = (v: any) => Number(v ?? 0).toFixed(2);
  const fees = Number(s.cod_total) - Number(s.net_payable);

  return (
    <div className="mx-auto max-w-3xl space-y-4">
      <div className="flex items-center justify-between print:hidden">
        <Link href="/finance/settlements" className="text-sm text-slate-500">← {tr(l, "settlements")}</Link>
        <div className="flex items-center gap-2">
          <SettlementActions id={s.id} status={s.status} t={{ submit: tr(l, "submit"), approve: tr(l, "approve"), pay: tr(l, "pay"), invoice: tr(l, "invoice") }} />
          <PrintButton label={tr(l, "print")} />
        </div>
      </div>

      <div className="card space-y-4">
        <div className="flex items-start justify-between border-b pb-3">
          <div>
            <div className="text-lg font-bold">{l === "ar" ? s.companies?.name_ar : s.companies?.name_en}</div>
            <div className="text-xs text-slate-500">{s.companies?.name_ar} · {s.companies?.name_en}</div>
            {s.companies?.trn && <div className="text-xs text-slate-500">TRN: {s.companies.trn}</div>}
          </div>
          <div className="text-end">
            <div className="text-sm font-semibold">{tr(l, "merchantStatement")}</div>
            <div className="font-mono text-xs" dir="ltr">{s.settlement_no}</div>
            <div className="text-xs text-slate-500" dir="ltr">{s.period_start} → {s.period_end}</div>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3 text-sm">
          <div><span className="text-slate-500">{tr(l, "merchant")}: </span>{s.merchants?.name}</div>
          <div><span className="text-slate-500">{tr(l, "status")}: </span>{tr(l, s.status)}</div>
          <div><span className="text-slate-500">{tr(l, "parcels")}: </span>{s.shipments_count}</div>
          <div><span className="text-slate-500">{tr(l, "cod")}: </span><span dir="ltr">{money(s.cod_total)} AED</span></div>
        </div>

        <table className="w-full">
          <thead className="border-y bg-slate-50"><tr>
            <th className="th">{tr(l, "serial")}</th><th className="th">{tr(l, "description")}</th><th className="th">{tr(l, "amount")}</th>
          </tr></thead>
          <tbody>
            {(lines ?? []).map((x: any) => (
              <tr key={x.id} className="border-b last:border-0">
                <td className="td font-mono text-xs">{x.shipments?.serial_number ?? "-"}</td>
                <td className="td text-xs">{x.description}</td>
                <td className={`td text-end ${Number(x.amount) < 0 ? "text-rose-700" : "text-emerald-700"}`} dir="ltr">{money(x.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <div className="ms-auto w-full max-w-xs space-y-1 text-sm">
          {[
            [tr(l, "cod"), s.cod_total],
            [tr(l, "fees"), -fees],
            [tr(l, "netPayable"), s.net_payable],
          ].map(([k, v]: any) => (
            <div key={k} className={`flex justify-between ${k === tr(l, "netPayable") ? "border-t pt-1 font-bold" : ""}`}>
              <span className="text-slate-600">{k}</span><span dir="ltr">{money(v)}</span>
            </div>
          ))}
        </div>

        {invoice && (
          <div className="border-t pt-2 text-xs text-slate-600">
            {tr(l, "invoice")}: <span className="font-mono">{invoice.invoice_no}</span> · {money(invoice.total)} AED · {invoice.status}
          </div>
        )}
      </div>
    </div>
  );
}
