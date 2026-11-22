"use client";
import { useActionState, useMemo, useState } from "react";
import { createDriver } from "./actions";
import { SubmitButton } from "@/components/SubmitButton";

type Opt = { id: string; name_ar: string; name_en: string };
type Area = Opt & { emirate_id: string };

export function NewDriverForm(p: { locale: "ar" | "en"; emirates: Opt[]; areas: Area[]; t: Record<string, string> }) {
  const [state, action] = useActionState(createDriver, undefined);
  const [emirate, setEmirate] = useState("");
  const areas = useMemo(() => p.areas.filter((a) => a.emirate_id === emirate), [p.areas, emirate]);
  const nm = (o: Opt) => (p.locale === "ar" ? o.name_ar : o.name_en);
  const t = p.t;

  return (
    <form action={action} className="card grid max-w-4xl grid-cols-1 gap-3 md:grid-cols-3">
      <div><label className="label">{t.name} *</label><input name="full_name" required className="input" /></div>
      <div><label className="label">{t.phone} *</label><input name="phone" required className="input" dir="ltr" /></div>
      <div><label className="label">{t.email}</label><input name="email" type="email" className="input" dir="ltr" /></div>

      <div><label className="label">{t.emirate} *</label>
        <select name="emirate_id" required className="input" value={emirate} onChange={(e) => setEmirate(e.target.value)}>
          <option value="" />{p.emirates.map((e) => <option key={e.id} value={e.id}>{nm(e)}</option>)}
        </select></div>
      <div><label className="label">{t.area}</label>
        <select name="area_id" className="input"><option value="" />{areas.map((a) => <option key={a.id} value={a.id}>{nm(a)}</option>)}</select></div>
      <div><label className="label">{t.commission} (AED)</label><input name="commission_per_delivery" type="number" step="0.01" min={0} defaultValue={0} className="input" dir="ltr" /></div>

      <div><label className="label">{t.employeeNo}</label><input name="employee_no" className="input" /></div>
      <div><label className="label">{t.hiredOn}</label><input name="hired_on" type="date" className="input" dir="ltr" /></div>
      <div><label className="label">{t.contractType}</label>
        <select name="contract_type" className="input"><option value="full_time">full_time</option><option value="part_time">part_time</option><option value="freelance">freelance</option><option value="commission">commission</option></select></div>

      <div><label className="label">License type</label>
        <select name="license_type" className="input"><option value="car">car</option><option value="motorcycle">motorcycle</option><option value="van">van</option><option value="truck">truck</option></select></div>
      <div><label className="label">{t.licenseExpiry}</label><input name="license_expiry" type="date" className="input" dir="ltr" /></div>
      <div />

      <div><label className="label">{t.vehicle}</label>
        <select name="vehicle_type" className="input"><option value="">-</option><option value="motorcycle">motorcycle</option><option value="car">car</option><option value="van">van</option><option value="truck">truck</option></select></div>
      <div><label className="label">{t.plate}</label><input name="plate_no" className="input" dir="ltr" /></div>
      <div />

      {state?.error && <p className="text-sm text-red-600 md:col-span-3">{state.error}</p>}
      <div className="md:col-span-3"><SubmitButton label={t.save} pending={t.saving} /></div>
    </form>
  );
}
