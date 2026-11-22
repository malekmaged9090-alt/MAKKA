import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";
import { markRead } from "./actions";

export const dynamic = "force-dynamic";

export default async function NotificationsPage() {
  const l = await getLocale();
  const supabase = await createClient();
  const { data } = await supabase.from("notifications").select("id,type,title,body,action_url,read_at,created_at").order("created_at", { ascending: false }).limit(100);
  return <div className="max-w-3xl space-y-4"><h1 className="text-xl font-bold">{tr(l, "notifications")}</h1><div className="space-y-2">{(data ?? []).map((n: any) => <div key={n.id} className={`card ${n.read_at ? "opacity-70" : "border-emerald-300"}`}><div className="flex items-start justify-between gap-3"><div><div className="font-semibold">{n.title ?? n.type}</div><p className="text-sm text-slate-600">{n.body}</p><div className="mt-1 text-xs text-slate-400" dir="ltr">{new Date(n.created_at).toLocaleString("en-GB", { timeZone: "Asia/Dubai" })}</div></div><div className="flex gap-2">{n.action_url && <Link className="btn-light text-xs" href={n.action_url}>{tr(l, "view")}</Link>}{!n.read_at && <form action={markRead}><input type="hidden" name="id" value={n.id} /><button className="btn-light text-xs">{tr(l, "markRead")}</button></form>}</div></div></div>)}{!data?.length && <div className="card text-slate-500">{tr(l, "noData")}</div>}</div></div>;
}
