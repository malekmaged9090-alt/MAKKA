import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr, nm } from "@/lib/i18n";
import { ReturnActions } from "./ReturnActions";

export const dynamic = "force-dynamic";

const statusKey: Record<string, string> = {
  requested: "requested", received_at_hub: "receivedAtHub", inspected: "inspected",
  returned_to_merchant: "returnedToMerchant", cancelled: "cancelled",
};

export default async function ReturnPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const l = await getLocale();
  const supabase = await createClient();
  const { data: r } = await supabase.from("returns")
    .select("*, merchants(name), shipments(id,serial_number,status_code,recipient_name,recipient_phone,cod_amount), branches(name_ar,name_en)")
    .eq("id", id).maybeSingle();
  if (!r) notFound();

  const fmt = (v: string | null) => v ? new Date(v).toLocaleString("en-GB", { timeZone: "Asia/Dubai" }) : "-";
  const row = (k: string, v: React.ReactNode) => (
    <div className="flex justify-between gap-4 border-b py-1.5 text-sm last:border-0">
      <span className="text-slate-500">{k}</span><span className="text-end">{v}</span>
    </div>
  );
  const t = {
    receive: tr(l, "receive"), inspect: tr(l, "inspect"), completeReturn: tr(l, "completeReturn"),
    cancelReturn: tr(l, "cancelReturn"), condition: tr(l, "condition"), good: tr(l, "good"),
    damaged: tr(l, "damaged"), missingItems: tr(l, "missingItems"), note: tr(l, "note"), done: tr(l, "done"),
  };
  const milestones = [
    ["requested", r.requested_at], ["received_at_hub", r.received_at],
    ["inspected", r.inspected_at], ["returned_to_merchant", r.completed_at],
  ].filter(([, v]) => v);

  return (
    <div className="grid max-w-5xl gap-4 md:grid-cols-3">
      <div className="space-y-4 md:col-span-2">
        <div className="flex items-center justify-between">
          <h1 className="font-mono text-xl font-bold" dir="ltr">{r.return_no}</h1>
          <Link href="/returns" className="btn-light">{tr(l, "back")}</Link>
        </div>

        <div className="card">
          {row(tr(l, "status"), <span className="rounded bg-slate-100 px-2 py-0.5 text-xs">{tr(l, statusKey[r.status] ?? r.status)}</span>)}
          {row(tr(l, "shipment"), <Link href={`/shipments/${r.shipments?.id}`} className="font-mono text-emerald-700 underline" dir="ltr">{r.shipments?.serial_number}</Link>)}
          {row(tr(l, "merchant"), r.merchants?.name ?? "-")}
          {row(tr(l, "recipient"), r.shipments?.recipient_name ?? "-")}
          {row(tr(l, "phone"), <span dir="ltr">{r.shipments?.recipient_phone ?? "-"}</span>)}
          {row(tr(l, "returnType"), r.return_type)}
          {row(tr(l, "returnReason"), r.reason_code)}
          {row(tr(l, "note"), r.reason_note ?? "-")}
          {row(tr(l, "branch"), r.branches ? nm(l, r.branches) : "-")}
          {row(tr(l, "condition"), r.condition ? tr(l, r.condition === "missing_items" ? "missingItems" : r.condition) : "-")}
          {row(tr(l, "inspection"), r.inspection_note ?? "-")}
        </div>

        <div className="card">
          <h2 className="mb-2 text-sm font-semibold">{tr(l, "timeline")}</h2>
          <ol className="space-y-2">
            {milestones.map(([s, v]) => (
              <li key={s as string} className="flex justify-between text-sm">
                <span>{tr(l, statusKey[s as string])}</span>
                <span className="text-xs text-slate-500" dir="ltr">{fmt(v as string)}</span>
              </li>
            ))}
            {r.cancelled_at && <li className="flex justify-between text-sm text-red-700"><span>{tr(l, "cancelled")}</span><span className="text-xs" dir="ltr">{fmt(r.cancelled_at)}</span></li>}
          </ol>
        </div>
      </div>

      <div className="space-y-4">
        <div className="card">
          <h2 className="mb-2 text-sm font-semibold">{tr(l, "actions")}</h2>
          <ReturnActions id={r.id} status={r.status} t={t} />
        </div>
      </div>
    </div>
  );
}
