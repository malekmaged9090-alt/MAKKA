"use client";
import { useActionState } from "react";
import { loadReport } from "./actions";
import { SubmitButton } from "@/components/SubmitButton";

const reportOptions = [
  ["all_shipments", "allShipments"], ["daily_shipments", "dailyShipments"], ["delivered", "deliveredReport"],
  ["failed", "failedReport"], ["returns", "returns"], ["driver_performance", "driverPerformance"],
  ["merchant_performance", "merchantPerformance"], ["by_emirate", "byEmirate"], ["by_area", "byArea"],
  ["daily_cod", "dailyCod"], ["driver_cash", "driverCash"], ["merchant_statement", "merchantStatement"],
  ["settlements", "settlementsReport"], ["finance", "financeReport"], ["overdue", "overdueReport"],
  ["attempts", "attemptsReport"], ["branch_movements", "branchMovements"], ["barcode_reprints", "barcodeReprints"],
];

export function ReportForm({ t, options }: { t: Record<string, string>; options: { id: string; label: string }[] }) {
  const [state, action] = useActionState(loadReport, undefined);
  const rows = state?.rows ?? [];
  const exportCsv = () => {
    if (!rows.length) return;
    const keys = [...new Set(rows.flatMap((r) => Object.keys(r)))];
    const esc = (v: unknown) => `"${String(v ?? "").replaceAll('"', '""')}"`;
    const csv = [keys.map(esc).join(","), ...rows.map((r) => keys.map((k) => esc(r[k])).join(","))].join("\n");
    const blob = new Blob(["\ufeff" + csv], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "makkah-report.csv"; a.click(); URL.revokeObjectURL(a.href);
  };
  return (
    <div className="space-y-4">
      <form action={action} className="card grid gap-3 md:grid-cols-4">
        <div className="md:col-span-2"><label className="label">{t.reportType}</label><select name="report" className="input">{reportOptions.map(([v,k]) => <option key={v} value={v}>{t[k]}</option>)}</select></div>
        <div><label className="label">{t.from}</label><input name="from" type="date" className="input" /></div>
        <div><label className="label">{t.to}</label><input name="to" type="date" className="input" /></div>
        <div><label className="label">{t.status}</label><input name="status" placeholder={t.statusOptional} className="input" /></div>
        <div><label className="label">{t.emirate}</label><select name="emirate" className="input" defaultValue=""><option value="">{t.all}</option>{options.filter((x) => x.id.startsWith("emirate:")).map((x) => <option key={x.id} value={x.id.slice(8)}>{x.label}</option>)}</select></div>
        <div><label className="label">{t.area}</label><select name="area" className="input" defaultValue=""><option value="">{t.all}</option>{options.filter((x) => x.id.startsWith("area:")).map((x) => <option key={x.id} value={x.id.slice(5)}>{x.label}</option>)}</select></div>
        <div><label className="label">{t.merchant}</label><select name="merchant" className="input" defaultValue=""><option value="">{t.all}</option>{options.filter((x) => x.id.startsWith("merchant:")).map((x) => <option key={x.id} value={x.id.slice(8)}>{x.label}</option>)}</select></div>
        <div><label className="label">{t.driver}</label><select name="driver" className="input" defaultValue=""><option value="">{t.all}</option>{options.filter((x) => x.id.startsWith("driver:")).map((x) => <option key={x.id} value={x.id.slice(7)}>{x.label}</option>)}</select></div>
        <div className="flex items-end"><SubmitButton label={t.runReport} pending="..." /></div>
        {state?.error && <p className="text-sm text-red-600 md:col-span-4">{state.error}</p>}
      </form>
      {state && !state.error && <div className="card space-y-3">
        <div className="flex items-center justify-between"><h2 className="font-semibold">{t.results} ({rows.length})</h2><button type="button" onClick={exportCsv} className="btn-light">{t.exportCsv}</button></div>
        <div className="overflow-x-auto"><table className="w-full"><thead><tr>{rows[0] && Object.keys(rows[0]).map((k) => <th className="th whitespace-nowrap" key={k}>{k}</th>)}</tr></thead><tbody>{rows.map((r, i) => <tr key={i}>{Object.keys(rows[0] ?? {}).map((k) => <td className="td whitespace-nowrap text-xs" key={k}>{typeof r[k] === "object" ? JSON.stringify(r[k]) : String(r[k] ?? "-")}</td>)}</tr>)}</tbody></table></div>
      </div>}
    </div>
  );
}
