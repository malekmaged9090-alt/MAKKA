"use client";
import { useActionState } from "react";
import { createMerchant } from "./actions";
import { SubmitButton } from "@/components/SubmitButton";
export default function NewMerchant() {
  const [state, action] = useActionState(createMerchant, undefined);
  return (
    <form action={action} className="card max-w-lg space-y-3">
      <div><label className="label">Name / الاسم</label><input name="name" required className="input" /></div>
      <div><label className="label">Trade name / الاسم التجاري</label><input name="trade_name" className="input" /></div>
      <div><label className="label">Phone / الهاتف</label><input name="phone" className="input" dir="ltr" /></div>
      <div><label className="label">Email</label><input name="email" type="email" className="input" dir="ltr" /></div>
      {state?.error && <p className="text-sm text-red-600">{state.error}</p>}
      <SubmitButton label="Save / حفظ" pending="..." />
    </form>
  );
}
