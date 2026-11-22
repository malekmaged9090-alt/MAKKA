"use client";
import { useActionState, useMemo, useState } from "react";
import { createShipment } from "./actions";
import { SubmitButton } from "@/components/SubmitButton";

type Opt = { id: string; name_ar: string; name_en: string };
type Area = Opt & { emirate_id: string };
const SERVICES = ["standard", "same_day", "next_day", "express", "scheduled", "return_pickup", "exchange", "document"];
const PAYMENTS = ["cod", "cash", "card", "online_paid", "prepaid"];

export function NewShipmentForm(p: {
  locale: "ar" | "en"; idemKey: string; merchants: { id: string; name: string }[] | null; emirates: Opt[]; areas: Area[]; t: Record<string, string>;
}) {
  const [state, action] = useActionState(createShipment, undefined);
  const [emirate, setEmirate] = useState("");
  const [payment, setPayment] = useState("cod");
  const nm = (o: Opt) => (p.locale === "ar" ? o.name_ar : o.name_en);
  const areas = useMemo(() => p.areas.filter((a) => a.emirate_id === emirate), [p.areas, emirate]);
  const t = p.t;
  return (
    <form action={action} className="card grid max-w-3xl grid-cols-1 gap-3 md:grid-cols-2">
      <input type="hidden" name="idempotency_key" value={p.idemKey} />
      {p.merchants && (
        <div><label className="label">{t.merchant}</label>
          <select name="merchant_id" required className="input"><option value="" />{p.merchants.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</select></div>
      )}
      <div><label className="label">{t.merchantRef}</label><input name="merchant_reference" className="input" /></div>
      <div><label className="label">{t.recipient}</label><input name="recipient_name" required className="input" /></div>
      <div><label className="label">{t.phone}</label><input name="recipient_phone" required className="input" dir="ltr" /></div>
      <div><label className="label">{t.emirate}</label>
        <select name="emirate_id" required className="input" value={emirate} onChange={(e) => setEmirate(e.target.value)}>
          <option value="" />{p.emirates.map((e) => <option key={e.id} value={e.id}>{nm(e)}</option>)}</select></div>
      <div><label className="label">{t.area}</label>
        <select name="area_id" className="input"><option value="" />{areas.map((a) => <option key={a.id} value={a.id}>{nm(a)}</option>)}</select></div>
      <div className="md:col-span-2"><label className="label">{t.address}</label><input name="address" required className="input" /></div>
      <div><label className="label">{t.service}</label><select name="service_type" className="input">{SERVICES.map((s) => <option key={s}>{s}</option>)}</select></div>
      <div><label className="label">{t.parcels}</label><input name="parcel_count" type="number" min={1} defaultValue={1} className="input" dir="ltr" /></div>
      <div><label className="label">{t.weight}</label><input name="weight_kg" type="number" step="0.001" min={0} className="input" dir="ltr" /></div>
      <div><label className="label">{t.goodsValue} (AED)</label><input name="goods_value" type="number" step="0.01" min={0} defaultValue={0} className="input" dir="ltr" /></div>
      <div><label className="label">{t.payment}</label>
        <select name="payment_method" className="input" value={payment} onChange={(e) => setPayment(e.target.value)}>{PAYMENTS.map((s) => <option key={s}>{s}</option>)}</select></div>
      <div><label className="label">COD (AED)</label><input name="cod_amount" type="number" step="0.01" min={0} defaultValue={0} readOnly={payment !== "cod"} className="input" dir="ltr" /></div>
      <div className="md:col-span-2"><label className="label">{t.description}</label><input name="description" className="input" /></div>
      <div className="md:col-span-2"><label className="label">{t.notes}</label><textarea name="notes" rows={2} className="input" /></div>
      {state?.error && <p className="text-sm text-red-600 md:col-span-2">{state.error}</p>}
      <div className="md:col-span-2"><SubmitButton label={t.save} pending={t.saving} /></div>
    </form>
  );
}
