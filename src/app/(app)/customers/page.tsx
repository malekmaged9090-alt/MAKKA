import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
export const dynamic = "force-dynamic";
export default async function Customers({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q } = await searchParams, l = await getLocale();
  const supabase = await createClient();
  let query = supabase.from("customers").select("id,full_name,phone,phone_alt,delivered_count,refused_count,created_at").order("created_at", { ascending: false }).limit(200);
  const term = (q ?? "").replace(/[%,()]/g, " ").trim();
  if (term) query = query.or(`full_name.ilike.%${term}%,phone.ilike.%${term}%,phone_alt.ilike.%${term}%`);
  const { data } = await query;
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">{tr(l, "customers")}</h1>
      <form className="card flex items-end gap-3"><div className="grow"><label className="label">{tr(l, "name")} / {tr(l, "phone")}</label><input name="q" defaultValue={q ?? ""} className="input" /></div><button className="btn-light">OK</button></form>
      <div className="card overflow-x-auto p-0"><table className="w-full">
        <thead className="border-b bg-slate-50"><tr>{[tr(l, "name"), tr(l, "phone"), tr(l, "deliveredCount"), tr(l, "refusedCount")].map((h) => <th key={h} className="th">{h}</th>)}</tr></thead>
        <tbody>{(data ?? []).map((c) => (<tr key={c.id} className="border-b last:border-0">
          <td className="td"><Link className="text-emerald-700 underline" href={`/customers/${c.id}`}>{c.full_name}</Link></td>
          <td className="td" dir="ltr">{c.phone}</td><td className="td">{c.delivered_count}</td>
          <td className={`td ${c.refused_count > 1 ? "font-semibold text-red-600" : ""}`}>{c.refused_count}</td></tr>))}
        {!data?.length && <tr><td colSpan={4} className="td text-center text-slate-500">{tr(l, "noData")}</td></tr>}</tbody></table></div>
    </div>
  );
}
