"use client";
import { useActionState } from "react";
import { closeSession, handoverCash } from "./actions";

type Session = {
  id: string; business_date: string; opening_balance: number; collected_cod: number;
  handed_over: number; driver_name: string;
};

export function FinanceForms(p: { t: Record<string, any>; sessions: Session[] }) {
  const [hState, hAction] = useActionState(handoverCash, undefined);
  const t = p.t;
  return (
    <div className="space-y-4">
      <form action={hAction} className="card space-y-2">
        <h2 className="text-sm font-semibold">{t.handover}</h2>
        <div><label className="label">{t.driver}</label>
          <select name="driver_id" required className="input">
            <option value="" />
            {t.drivers.map((d: any) => <option key={d.id} value={d.id}>{d.name}</option>)}
          </select></div>
        <div><label className="label">{t.collectedAmount} (AED)</label><input name="amount" type="number" step="0.01" min={0.01} required className="input" dir="ltr" /></div>
        <div><label className="label">{t.reference}</label><input name="reference" className="input" /></div>
        <div><label className="label">{t.note}</label><input name="note" className="input" /></div>
        {hState?.error && <p className="text-xs text-red-600">{hState.error}</p>}
        {hState?.ok && <p className="text-xs text-emerald-700">{hState.ok}</p>}
        <button className="btn w-full">{t.save}</button>
      </form>

      <div className="card space-y-3">
        <h2 className="text-sm font-semibold">{t.openSessions}</h2>
        {p.sessions.map((s) => <CloseRow key={s.id} s={s} t={t} />)}
        {!p.sessions.length && <p className="text-xs text-slate-500">{t.noData}</p>}
      </div>
    </div>
  );
}

function CloseRow({ s, t }: { s: Session; t: Record<string, any> }) {
  const [state, action] = useActionState(closeSession, undefined);
  return (
    <form action={action} className="space-y-1 border-b pb-2 last:border-0">
      <input type="hidden" name="session_id" value={s.id} />
      <div className="flex justify-between text-xs"><span className="font-medium">{s.driver_name}</span><span dir="ltr">{s.business_date}</span></div>
      <div className="flex justify-between text-[11px] text-slate-500">
        <span>{t.collectedToday}: {Number(s.collected_cod).toFixed(2)}</span>
        <span>{t.cashHandedToday}: {Number(s.handed_over).toFixed(2)}</span>
      </div>
      <div className="flex gap-1">
        <input name="counted" type="number" step="0.01" min={0} placeholder={t.countedCash} className="input h-8 w-24" dir="ltr" />
        <input name="note" placeholder={t.note} className="input h-8 flex-1" />
        <button className="btn-light h-8">{t.closeSession}</button>
      </div>
      {state?.error && <p className="text-[11px] text-red-600">{state.error}</p>}
      {state?.ok && <p className="text-[11px] text-emerald-700">{state.ok}</p>}
    </form>
  );
}
