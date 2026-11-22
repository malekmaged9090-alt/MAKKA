"use client";
import { useActionState } from "react";
import { previewShipments, commitShipments, type ImportState } from "./actions";
const COLOR: Record<string, string> = { new: "text-emerald-700", duplicate: "text-amber-700", error: "text-red-600" };
export function ImportForm({ merchants, fixedMerchant, t }: { merchants: { id: string; name: string }[]; fixedMerchant: boolean; t: Record<string, string> }) {
  const [pv, previewAction, p1] = useActionState<ImportState | undefined, FormData>(previewShipments, undefined);
  const [cm, commitAction, p2] = useActionState<ImportState | undefined, FormData>(commitShipments, undefined);
  const rows = (cm?.rows ?? pv?.rows) ?? [];
  const n = (s: string) => rows.filter((r) => r.status === s).length;
  const done = cm?.done; const canImport = pv?.rows && !pv.error && n("error") === 0 && n("new") > 0 && !done;
  return (
    <form className="space-y-4">
      <div className="card flex flex-wrap items-end gap-3">
        {!fixedMerchant && <div><label className="label">{t.merchant}</label>
          <select name="merchant_id" required className="input min-w-56" defaultValue=""><option value="" disabled>—</option>{merchants.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</select></div>}
        <div><label className="label">Excel (.xlsx)</label><input type="file" name="file" accept=".xlsx" required className="input" /></div>
        <button formAction={previewAction} disabled={p1 || p2} className="btn-light">{t.preview}</button>
        <button formAction={commitAction} disabled={!canImport || p1 || p2} className="btn">{t.import} {canImport ? n("new") : ""}</button>
        <a href="/shipments/import/template" className="btn-light">{t.template}</a>
      </div>
      {(pv?.error || cm?.error) && <p className="text-sm text-red-600">{cm?.error ?? pv?.error}</p>}
      {done && <p className="rounded bg-emerald-50 p-3 text-sm text-emerald-800">✓ {done.inserted} {t.created} — <a className="underline" href="/shipments">{t.openList}</a></p>}
      {rows.length > 0 && (<>
        <p className="text-sm">{t.new}: <b>{n("new")}</b> · {t.duplicates}: {n("duplicate")} · {t.errors}: <b className="text-red-600">{n("error")}</b></p>
        <div className="card max-h-[30rem] overflow-auto p-0"><table className="w-full">
          <thead className="sticky top-0 border-b bg-slate-50"><tr>{["#", t.recipient, t.phone, t.address, "COD", t.status].map((h) => <th key={h} className="th">{h}</th>)}</tr></thead>
          <tbody>{rows.map((r) => (<tr key={r.line} className="border-b last:border-0 align-top"><td className="td">{r.line}</td><td className="td">{r.recipient_name}</td><td className="td" dir="ltr">{r.recipient_phone}</td>
            <td className="td">{r.address}</td><td className="td">{r.cod_amount}</td><td className={`td ${COLOR[r.status]}`}>{r.status}{r.messages.length ? ` — ${r.messages.join("; ")}` : ""}</td></tr>))}</tbody></table></div>
      </>)}
    </form>
  );
}
