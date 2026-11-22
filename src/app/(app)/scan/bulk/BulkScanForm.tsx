"use client";
import { useActionState } from "react";
import { bulkScan } from "../actions";
import { SubmitButton } from "@/components/SubmitButton";

export function BulkScanForm({ t }: { t: Record<string, string> }) {
  const [state, action] = useActionState(bulkScan, undefined);
  const r = state?.data;
  const badge = (x: string) =>
    x === "ok" ? "bg-emerald-100 text-emerald-800" :
    x === "duplicate" ? "bg-amber-100 text-amber-800" :
    x === "not_found" ? "bg-slate-200 text-slate-600" : "bg-red-100 text-red-700";

  return (
    <div className="space-y-4">
      <form action={action} className="card space-y-3">
        <div>
          <label className="label">{t.scanType}</label>
          <select name="scan_type" className="input" defaultValue="receive_at_hub">
            <option value="receive_at_hub">{t.receiveAtHub}</option>
            <option value="sorting">{t.sorting}</option>
            <option value="load_to_driver">{t.loadToDriver}</option>
            <option value="return_receive">{t.returnReceive}</option>
            <option value="return_to_merchant">{t.returnToMerchant}</option>
          </select>
        </div>
        <div>
          <label className="label">{t.codes} — {t.onePerLine}</label>
          <textarea name="codes" required rows={10} dir="ltr" className="input font-mono" placeholder={"MKK-2026-000001\nMKK-2026-000002"} />
        </div>
        <input name="note" placeholder={t.note} className="input" />
        {state?.error && <p className="text-sm text-red-600">{state.error === "empty" ? t.required : state.error}</p>}
        <SubmitButton label={t.runScan} pending="..." />
      </form>

      {r && (
        <div className="card space-y-3">
          <div className="flex flex-wrap gap-3 text-sm">
            <span className="rounded bg-emerald-100 px-2 py-1 text-emerald-800">{t.scanOk}: {r.ok}</span>
            <span className="rounded bg-amber-100 px-2 py-1 text-amber-800">{t.scanDuplicates}: {r.duplicates}</span>
            <span className="rounded bg-slate-200 px-2 py-1 text-slate-700">{t.scanNotFound}: {r.not_found}</span>
            <span className="rounded bg-red-100 px-2 py-1 text-red-700">{t.scanRejected}: {r.rejected}</span>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead><tr>
                <th className="th">{t.codes}</th><th className="th">{t.serial}</th>
                <th className="th">{t.status}</th><th className="th">{t.scanResults}</th>
              </tr></thead>
              <tbody>
                {(r.results ?? []).map((x: any, i: number) => (
                  <tr key={i}>
                    <td className="td font-mono" dir="ltr">{x.code}</td>
                    <td className="td font-mono" dir="ltr">{x.serial ?? "-"}</td>
                    <td className="td">{x.status ?? "-"}</td>
                    <td className="td">
                      <span className={`rounded px-2 py-0.5 text-xs ${badge(x.result)}`}>{x.result}</span>
                      {x.reason && <span className="ms-2 text-xs text-slate-500">{x.reason}</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
