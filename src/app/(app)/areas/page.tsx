import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
import { toggleArea } from "./actions";
export const dynamic = "force-dynamic";
type SP = { emirate?: string; q?: string; review?: string };
export default async function Areas({ searchParams }: { searchParams: Promise<SP> }) {
  const sp = await searchParams, l = await getLocale();
  const supabase = await createClient();
  const { data: emirates } = await supabase.from("emirates").select("id,code,name_ar,name_en").order("sort_order");
  let q = supabase.from("areas").select("id,name_ar,name_en,is_active,is_covered,needs_review,emirates(code),service_zones(name)").order("name_en").limit(500);
  if (sp.emirate) q = q.eq("emirate_id", sp.emirate);
  if (sp.review === "1") q = q.eq("needs_review", true);
  if (sp.q) { const t = sp.q.replace(/[%,()]/g, " ").trim(); if (t) q = q.or(`name_en.ilike.%${t}%,name_ar.ilike.%${t}%`); }
  const { data } = await q;
  const { data: canManage } = await supabase.rpc("has_permission", { p: "geo.manage" });
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-bold">{tr(l, "areas")}</h1>
        {canManage === true && <Link href="/areas/import" className="btn">{tr(l, "importAreas")}</Link>}
      </div>
      <form className="card flex flex-wrap items-end gap-3">
        <div><label className="label">{tr(l, "emirate")}</label>
          <select name="emirate" defaultValue={sp.emirate ?? ""} className="input"><option value="">—</option>{(emirates ?? []).map((e) => <option key={e.id} value={e.id}>{l === "ar" ? e.name_ar : e.name_en}</option>)}</select></div>
        <div><label className="label">{tr(l, "name")}</label><input name="q" defaultValue={sp.q ?? ""} className="input" /></div>
        <label className="flex items-center gap-2 pb-2 text-sm"><input type="checkbox" name="review" value="1" defaultChecked={sp.review === "1"} />{tr(l, "needsReview")}</label>
        <button className="btn-light">{tr(l, "search").split(" ")[0]}</button>
      </form>
      <div className="card overflow-x-auto p-0"><table className="w-full">
        <thead className="border-b bg-slate-50"><tr>{[tr(l, "emirate"), "English", "العربي", tr(l, "zone"), tr(l, "needsReview"), tr(l, "covered"), tr(l, "status")].map((h) => <th key={h} className="th">{h}</th>)}</tr></thead>
        <tbody>{(data ?? []).map((a) => {
          const em = a.emirates as unknown as { code: string } | null, z = a.service_zones as unknown as { name: string } | null;
          const btn = (field: string, on: boolean, label: string) => canManage === true
            ? <form action={toggleArea}><input type="hidden" name="id" value={a.id} /><input type="hidden" name="field" value={field} /><button className="underline">{label}</button></form> : <span>{label}</span>;
          return (<tr key={a.id} className="border-b last:border-0">
            <td className="td">{em?.code}</td><td className="td" dir="ltr">{a.name_en}</td><td className="td">{a.name_ar}</td><td className="td">{z?.name}</td>
            <td className="td">{btn("needs_review", a.needs_review, a.needs_review ? "⚑ " + tr(l, "yes") : "—")}</td>
            <td className="td">{btn("is_covered", a.is_covered, a.is_covered ? tr(l, "yes") : tr(l, "no"))}</td>
            <td className={`td ${a.is_active ? "" : "text-slate-400"}`}>{btn("is_active", a.is_active, a.is_active ? tr(l, "active") : tr(l, "disabled"))}</td></tr>);
        })}
        {!data?.length && <tr><td colSpan={7} className="td text-center text-slate-500">{tr(l, "noData")}</td></tr>}</tbody></table></div>
    </div>
  );
}
