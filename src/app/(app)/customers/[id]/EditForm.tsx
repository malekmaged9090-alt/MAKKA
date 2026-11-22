"use client";
import { useActionState } from "react";
import { updateCustomer } from "./actions";
import { SubmitButton } from "@/components/SubmitButton";
export function EditForm({ c, t }: { c: { id: string; full_name: string; phone_alt: string | null; notes: string | null }; t: Record<string, string> }) {
  const [st, action] = useActionState(updateCustomer, undefined);
  return (
    <form action={action} className="card space-y-3 max-w-lg"><input type="hidden" name="id" value={c.id} />
      <div><label className="label">{t.name}</label><input name="full_name" defaultValue={c.full_name} required className="input" /></div>
      <div><label className="label">{t.phoneAlt}</label><input name="phone_alt" defaultValue={c.phone_alt ?? ""} className="input" dir="ltr" /></div>
      <div><label className="label">{t.notes}</label><textarea name="notes" defaultValue={c.notes ?? ""} rows={3} className="input" /></div>
      {st?.error && <p className="text-sm text-red-600">{st.error}</p>}{st?.ok && <p className="text-sm text-emerald-700">✓</p>}
      <SubmitButton label={t.save} pending="..." />
    </form>
  );
}
