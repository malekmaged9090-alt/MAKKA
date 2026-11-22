import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr, nm } from "@/lib/i18n";
import { StatusBadge, type StatusRow } from "@/components/StatusBadge";
import { EditForm } from "./EditForm";
export const dynamic = "force-dynamic";
export default async function CustomerPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params, l = await getLocale();
  const supabase = await createClient();
  const { data: c } = await supabase.from("customers").select("id,full_name,phone,phone_alt,notes,delivered_count,refused_count").eq("id", id).maybeSingle();
  if (!c) notFound();
  const [{ data: ships }, { data: addrs }, { data: statuses }, { data: manage }] = await Promise.all([
    supabase.from("shipments").select("id,serial_number,status_code,created_at,cod_amount,delivery_address_text").eq("customer_id", id).order("created_at", { ascending: false }).limit(50),
    supabase.from("customer_addresses").select("id,street,building_name,landmark,is_default,emirates:emirate_id(name_ar,name_en),areas:area_id(name_ar,name_en)").eq("customer_id", id).eq("is_active", true),
    supabase.from("shipment_statuses").select("code,name_ar,name_en,color"),
    supabase.rpc("has_permission", { p: "customers.manage" }),
  ]);
  const st = new Map((statuses as StatusRow[] ?? []).map((s) => [s.code, s]));
  const t = { name: tr(l, "name"), phoneAlt: tr(l, "phoneAlt"), notes: tr(l, "notes"), save: tr(l, "save") };
  return (
    <div className="max-w-4xl space-y-4">
      <h1 className="text-xl font-bold">{c.full_name} <span className="text-sm font-normal text-slate-500" dir="ltr">{c.phone}</span></h1>
      <div className="card grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
        <div>{tr(l, "deliveredCount")}: <b>{c.delivered_count}</b></div><div>{tr(l, "refusedCount")}: <b className={c.refused_count > 1 ? "text-red-600" : ""}>{c.refused_count}</b></div>
        <div>{tr(l, "shipments")}: <b>{ships?.length ?? 0}</b></div>
      </div>
      {manage === true ? <EditForm c={c} t={t} /> : c.notes && <div className="card text-sm">{c.notes}</div>}
      {!!addrs?.length && <div className="card space-y-1 text-sm"><h2 className="font-semibold">{tr(l, "addresses")}</h2>
        {addrs.map((a) => <div key={a.id}>{nm(l, a.emirates as unknown as { name_ar: string; name_en: string } | null)} · {nm(l, a.areas as unknown as { name_ar: string; name_en: string } | null)} · {a.street} {a.building_name} {a.landmark}{a.is_default ? " ★" : ""}</div>)}</div>}
      <div className="card overflow-x-auto p-0"><table className="w-full">
        <thead className="border-b bg-slate-50"><tr>{[tr(l, "serial"), tr(l, "status"), "COD", tr(l, "created")].map((h) => <th key={h} className="th">{h}</th>)}</tr></thead>
        <tbody>{(ships ?? []).map((s) => (<tr key={s.id} className="border-b last:border-0"><td className="td" dir="ltr"><Link className="text-emerald-700 underline" href={`/shipments/${s.id}`}>{s.serial_number}</Link></td>
          <td className="td"><StatusBadge status={st.get(s.status_code)} locale={l} /></td><td className="td">{Number(s.cod_amount).toFixed(2)}</td>
          <td className="td">{new Date(s.created_at).toLocaleDateString("en-GB", { timeZone: "Asia/Dubai" })}</td></tr>))}
        {!ships?.length && <tr><td colSpan={4} className="td text-center text-slate-500">{tr(l, "noData")}</td></tr>}</tbody></table></div>
    </div>
  );
}
