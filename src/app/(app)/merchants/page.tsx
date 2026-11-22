import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
export const dynamic = "force-dynamic";
export default async function Merchants() {
  const l = await getLocale();
  const supabase = await createClient();
  const { data } = await supabase.from("merchants").select("id,merchant_no,name,trade_name,phone,status").order("merchant_no", { ascending: false }).limit(200);
  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between"><h1 className="text-xl font-bold">{tr(l, "merchants")}</h1><Link href="/merchants/new" className="btn">{tr(l, "newMerchant")}</Link></div>
      <div className="card overflow-x-auto p-0"><table className="w-full">
        <thead className="border-b bg-slate-50"><tr><th className="th">#</th><th className="th">{tr(l, "name")}</th><th className="th">{tr(l, "tradeName")}</th><th className="th">{tr(l, "phone")}</th><th className="th">{tr(l, "status")}</th></tr></thead>
        <tbody>{(data ?? []).map((m) => (<tr key={m.id} className="border-b last:border-0"><td className="td">{m.merchant_no}</td><td className="td"><Link className="text-emerald-700 underline" href={`/merchants/${m.id}`}>{m.name}</Link></td><td className="td">{m.trade_name}</td><td className="td" dir="ltr">{m.phone}</td><td className="td">{m.status}</td></tr>))}
        {!data?.length && <tr><td colSpan={5} className="td text-center text-slate-500">{tr(l, "noData")}</td></tr>}</tbody></table></div>
    </div>
  );
}
