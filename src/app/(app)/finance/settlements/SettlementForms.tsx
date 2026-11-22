"use client";
import { useActionState } from "react";
import { createSettlement, settlementAction } from "../actions";

export function NewSettlement(p: { merchants: { id: string; name: string }[]; today: string; weekAgo: string; t: Record<string, string> }) {
  const [state, action] = useActionState(createSettlement, undefined);
  const t = p.t;
  return (
    <form action={action} className="card grid gap-2 md:grid-cols-4">
      <div className="md:col-span-2"><label className="label">{t.merchant}</label>
        <select name="merchant_id" required className="input"><option value="" />{p.merchants.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</select></div>
      <div><label className="label">{t.periodFrom}</label><input name="from" type="date" required defaultValue={p.weekAgo} className="input" dir="ltr" /></div>
      <div><label className="label">{t.periodTo}</label><input name="to" type="date" required defaultValue={p.today} className="input" dir="ltr" /></div>
      <div className="md:col-span-4 flex items-center gap-3">
        <button className="btn">{t.createSettlement}</button>
        <span className="text-xs text-slate-500">{t.newSettlementHint}</span>
      </div>
      {state?.error && <p className="text-xs text-red-600 md:col-span-4">{state.error}</p>}
      {state?.ok && <p className="text-xs text-emerald-700 md:col-span-4">{state.ok}</p>}
    </form>
  );
}

export function SettlementActions(p: { id: string; status: string; t: Record<string, string> }) {
  const [state, action] = useActionState(settlementAction, undefined);
  const t = p.t;
  return (
    <form action={action} className="flex flex-wrap items-center gap-1">
      <input type="hidden" name="id" value={p.id} />
      {p.status === "draft" && <button name="op" value="submit" className="btn-light h-7 text-xs">{t.submit}</button>}
      {["draft", "under_review"].includes(p.status) && <button name="op" value="approve" className="btn h-7 text-xs">{t.approve}</button>}
      {p.status === "approved" && <button name="op" value="pay" className="btn h-7 text-xs">{t.pay}</button>}
      {["approved", "paid"].includes(p.status) && <button name="op" value="invoice" className="btn-light h-7 text-xs">{t.invoice}</button>}
      {state?.error && <span className="text-[11px] text-red-600">{state.error}</span>}
    </form>
  );
}
