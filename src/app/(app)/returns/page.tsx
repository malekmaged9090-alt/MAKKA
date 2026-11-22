import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getLocale, tr } from "@/lib/i18n";

export const dynamic = "force-dynamic";

const statusKey: Record<string, string> = {
  requested: "requested", received_at_hub: "receivedAtHub", inspected: "inspected",
  returned_to_merchant: "returnedToMerchant", cancelled: "cancelled",
};
const statusColor: Record<string, string> = {
  requested: "bg-amber-100 text-amber-800", received_at_hub: "bg-sky-100 text-sky-800",
  inspected: "bg-indigo-100 text-indigo-800", returned_to_merchant: "bg-emerald-100 text-emerald-800",
  cancelled: "bg-slate-200 text-slate-600",
};

export default async function ReturnsPage() {
  const l = await getLocale();
  const supabase = await createClient();
  const { data } = await supabase.from("returns")
    .select("id,return_no,status,reason_code,return_type,created_at,condition,merchants(name),shipments(serial_number,recipient_name)")
    .order("created_at", { ascending: false }).limit(200);
  const rows = data ?? [];
  const count = (s: string) => rows.filter((r: any) => r.status === s).length;

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold">{tr(l, "returns")}</h1>
        <p className="text-sm text-slate-500">{tr(l, "returnsHint")}</p>
      </div>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        {[["requested", count("requested")], ["received_at_hub", count("received_at_hub")],
          ["inspected", count("inspected")], ["returned_to_merchant", count("returned_to_merchant")]].map(([s, n]) => (
          <div key={s as string} className="card py-3">
            <div className="text-xs text-slate-500">{tr(l, statusKey[s as string])}</div>
            <div className="text-2xl font-bold">{n as number}</div>
          </div>
        ))}
      </div>

      <div className="card overflow-x-auto p-0">
        <table className="w-full">
          <thead><tr>
            <th className="th">{tr(l, "returnNo")}</th><th className="th">{tr(l, "serial")}</th>
            <th className="th">{tr(l, "merchant")}</th><th className="th">{tr(l, "returnReason")}</th>
            <th className="th">{tr(l, "condition")}</th><th className="th">{tr(l, "status")}</th>
            <th className="th">{tr(l, "created")}</th><th className="th"></th>
          </tr></thead>
          <tbody>
            {rows.map((r: any) => (
              <tr key={r.id}>
                <td className="td font-mono" dir="ltr">{r.return_no}</td>
                <td className="td font-mono" dir="ltr">{r.shipments?.serial_number ?? "-"}</td>
                <td className="td">{r.merchants?.name ?? "-"}</td>
                <td className="td">{r.reason_code}</td>
                <td className="td">{r.condition ? tr(l, r.condition === "missing_items" ? "missingItems" : r.condition) : "-"}</td>
                <td className="td"><span className={`rounded px-2 py-0.5 text-xs ${statusColor[r.status] ?? ""}`}>{tr(l, statusKey[r.status] ?? r.status)}</span></td>
                <td className="td text-xs" dir="ltr">{new Date(r.created_at).toLocaleDateString("en-GB")}</td>
                <td className="td"><Link href={`/returns/${r.id}`} className="text-emerald-700 underline">{tr(l, "view")}</Link></td>
              </tr>
            ))}
            {!rows.length && <tr><td className="td text-slate-500" colSpan={8}>{tr(l, "noData")}</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
