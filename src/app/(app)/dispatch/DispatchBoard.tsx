"use client";
import { useActionState, useState } from "react";
import { assignSelected, autoDispatchAll } from "./actions";

type Row = {
  id: string; serial_number: string; recipient_name: string; cod_amount: number;
  service_type: string; area: string; merchant: string; created_at: string;
};
type Drv = {
  id: string; full_name: string; status: string; load: number; coverage: string;
};

export function DispatchBoard(p: { rows: Row[]; drivers: Drv[]; allIds: string[]; t: Record<string, string> }) {
  const [assignState, assignAction] = useActionState(assignSelected, undefined);
  const [autoState, autoAction] = useActionState(autoDispatchAll, undefined);
  const [selected, setSelected] = useState<string[]>([]);
  const allChecked = p.rows.length > 0 && selected.length === p.rows.length;
  const toggle = (id: string) => setSelected((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]));

  return (
    <div className="space-y-4">
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="card p-0 lg:col-span-2">
          <div className="flex items-center justify-between border-b px-4 py-3">
            <h2 className="text-sm font-semibold">{p.t.readyForDispatch} ({p.rows.length})</h2>
            <label className="flex items-center gap-2 text-xs text-slate-600">
              <input type="checkbox" checked={allChecked} onChange={() => setSelected(allChecked ? [] : p.rows.map((r) => r.id))} />
              {p.t.selectAll}
            </label>
          </div>
          <div className="max-h-[520px] overflow-auto">
            <table className="w-full">
              <thead className="sticky top-0 border-b bg-slate-50"><tr>
                <th className="th w-8" /><th className="th">{p.t.serial}</th><th className="th">{p.t.recipient}</th>
                <th className="th">{p.t.area}</th><th className="th">{p.t.cod}</th>
              </tr></thead>
              <tbody>
                {p.rows.map((r) => (
                  <tr key={r.id} className={`border-b last:border-0 ${selected.includes(r.id) ? "bg-emerald-50" : "hover:bg-slate-50"}`}>
                    <td className="td"><input type="checkbox" checked={selected.includes(r.id)} onChange={() => toggle(r.id)} /></td>
                    <td className="td font-mono text-xs">{r.serial_number}</td>
                    <td className="td"><div className="font-medium">{r.recipient_name}</div><div className="text-xs text-slate-500">{r.merchant}</div></td>
                    <td className="td text-xs">{r.area || "-"}</td>
                    <td className="td" dir="ltr">{Number(r.cod_amount).toFixed(2)}</td>
                  </tr>
                ))}
                {!p.rows.length && <tr><td colSpan={5} className="td py-8 text-center text-slate-500">{p.t.noDispatch}</td></tr>}
              </tbody>
            </table>
          </div>
        </div>

        <div className="space-y-4">
          <form action={assignAction} className="card space-y-3">
            <h2 className="text-sm font-semibold">{p.t.assignSelected} ({selected.length})</h2>
            {selected.map((id) => <input key={id} type="hidden" name="ids" value={id} />)}
            <select name="driver_id" required className="input">
              <option value="">{p.t.driver}…</option>
              {p.drivers.map((d) => (
                <option key={d.id} value={d.id}>{d.full_name} — {d.load} · {d.coverage || "-"}</option>
              ))}
            </select>
            <button className="btn w-full" disabled={!selected.length || !p.drivers.length}>{p.t.assign}</button>
            {assignState?.error && <p className="text-xs text-red-600">{assignState.error}</p>}
            {assignState?.ok && <p className="text-xs text-emerald-700">{assignState.ok}</p>}
          </form>

          <form action={autoAction} className="card space-y-2">
            <h2 className="text-sm font-semibold">{p.t.autoDispatch}</h2>
            <p className="text-xs text-slate-500">{p.t.autoHint}</p>
            {p.allIds.map((id) => <input key={id} type="hidden" name="ids" value={id} />)}
            <button className="btn-light w-full">{p.t.autoDispatch}</button>
            {autoState?.error && <p className="text-xs text-red-600">{autoState.error}</p>}
            {autoState?.ok && <p className="text-xs text-emerald-700">{autoState.ok}</p>}
          </form>
        </div>
      </div>

      <div className="card overflow-x-auto p-0">
        <h2 className="border-b px-4 py-3 text-sm font-semibold">{p.t.drivers}</h2>
        <table className="w-full">
          <thead className="border-b bg-slate-50"><tr>
            <th className="th">{p.t.name}</th><th className="th">{p.t.status}</th><th className="th">{p.t.load}</th><th className="th">{p.t.coverage}</th>
          </tr></thead>
          <tbody>
            {p.drivers.map((d) => (
              <tr key={d.id} className="border-b last:border-0">
                <td className="td font-medium">{d.full_name}</td>
                <td className="td text-xs">{p.t[d.status] ?? d.status}</td>
                <td className="td">{d.load}</td>
                <td className="td text-xs text-slate-600">{d.coverage || "-"}</td>
              </tr>
            ))}
            {!p.drivers.length && <tr><td colSpan={4} className="td text-center text-slate-500">{p.t.noDrivers}</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
