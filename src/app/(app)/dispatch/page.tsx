import { createClient } from "@/lib/supabase/server";
import { getLocale, tr, nm } from "@/lib/i18n";
import { DispatchBoard } from "./DispatchBoard";
import { closeManifest, reassignFromDispatch } from "./actions";

export const dynamic = "force-dynamic";

export default async function Dispatch({ searchParams }: { searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { error, ok } = await searchParams;
  const l = await getLocale();
  const supabase = await createClient();
  const [{ data: shipments }, { data: drivers }, { data: loads }, { data: manifests }, { data: assigned }] = await Promise.all([
    supabase.from("shipments")
      .select("id,serial_number,recipient_name,cod_amount,service_type,created_at,areas:delivery_area_id(name_ar,name_en),merchants(name)")
      .eq("status_code", "READY_FOR_DISPATCH").order("created_at").limit(300),
    supabase.from("drivers")
      .select("id,full_name,status,emirates:emirate_id(name_ar,name_en),driver_area_assignments(areas:area_id(name_ar,name_en),emirates:emirate_id(name_ar,name_en))")
      .eq("is_active", true).not("status", "in", "(suspended,inactive)").order("full_name"),
    supabase.from("shipment_assignments").select("driver_id,shipments!inner(status_code)").eq("is_current", true)
      .in("shipments.status_code", ["ASSIGNED_TO_DRIVER", "OUT_FOR_DELIVERY"]),   // delivered/failed shipments are not "load"
    supabase.from("dispatch_manifests")
      .select("id,manifest_no,status,total_shipments,delivered_count,failed_count,created_at,drivers(full_name),shipment_assignments(count)")
      .order("created_at", { ascending: false }).limit(10),
    supabase.from("shipment_assignments")
      .select("shipment_id,driver_id,shipments(serial_number,status_code),drivers(full_name)")
      .eq("is_current", true).limit(60),
  ]);

  const load = new Map<string, number>();
  (loads ?? []).forEach((r: any) => load.set(r.driver_id, (load.get(r.driver_id) ?? 0) + 1));

  const rows = (shipments ?? []).map((s: any) => ({
    id: s.id, serial_number: s.serial_number, recipient_name: s.recipient_name,
    cod_amount: Number(s.cod_amount ?? 0), service_type: s.service_type,
    area: nm(l, s.areas), merchant: s.merchants?.name ?? "", created_at: s.created_at,
  }));
  const drv = (drivers ?? []).map((d: any) => ({
    id: d.id, full_name: d.full_name, status: d.status, load: load.get(d.id) ?? 0,
    coverage: (d.driver_area_assignments ?? []).map((a: any) => nm(l, a.areas) || nm(l, a.emirates)).filter(Boolean).join("، ")
      || nm(l, d.emirates),
  }));
  const driverOptions = (drivers ?? []).map((d: any) => ({ id: d.id, full_name: d.full_name }));

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">{tr(l, "dispatch")}</h1>
      {error && <div className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">{error}</div>}
      {ok && <div className="rounded border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700">{ok === "closed" ? tr(l, "manifestClosed") : tr(l, "success")}</div>}

      <DispatchBoard rows={rows} drivers={drv} allIds={rows.map((r) => r.id)} t={{
        readyForDispatch: l === "ar" ? "جاهز للتوزيع" : "Ready for dispatch",
        selectAll: tr(l, "selectAll"), serial: tr(l, "serial"), recipient: tr(l, "recipient"),
        area: tr(l, "area"), cod: tr(l, "cod"), noDispatch: tr(l, "noDispatch"),
        assignSelected: tr(l, "assignSelected"), driver: tr(l, "driver"), assign: tr(l, "assign"),
        autoDispatch: tr(l, "autoDispatch"), autoHint: l === "ar" ? "يوزّع الشحنات على السائقين حسب التغطية وأقل حمل" : "Matches shipments to drivers by coverage and lowest load",
        drivers: tr(l, "drivers"), name: tr(l, "name"), status: tr(l, "status"), load: tr(l, "load"),
        coverage: tr(l, "coverage"), noDrivers: tr(l, "noDrivers"),
        available: tr(l, "available"), busy: tr(l, "busy"), on_delivery: tr(l, "onDelivery"),
        offline: tr(l, "offline"), on_break: tr(l, "onBreak"), suspended: tr(l, "suspended"), inactive: tr(l, "inactive"),
      }} />

      <div className="card overflow-x-auto p-0">
        <h2 className="border-b px-4 py-3 text-sm font-semibold">{tr(l, "activeAssignments")}</h2>
        <table className="w-full">
          <thead className="border-b bg-slate-50"><tr>
            <th className="th">{tr(l, "serial")}</th><th className="th">{tr(l, "status")}</th>
            <th className="th">{tr(l, "driver")}</th><th className="th">{tr(l, "reassign")}</th>
          </tr></thead>
          <tbody>
            {(assigned ?? []).map((a: any) => (
              <tr key={a.shipment_id} className="border-b last:border-0">
                <td className="td font-mono text-xs" dir="ltr">{a.shipments?.serial_number}</td>
                <td className="td text-xs">{a.shipments?.status_code}</td>
                <td className="td text-sm">{a.drivers?.full_name}</td>
                <td className="td">
                  <form action={reassignFromDispatch} className="flex flex-wrap items-center gap-1">
                    <input type="hidden" name="shipment_id" value={a.shipment_id} />
                    <select name="driver_id" className="input w-40 py-1 text-xs" required defaultValue="">
                      <option value="" disabled>{tr(l, "reassignTo")}</option>
                      {driverOptions.filter((d) => d.id !== a.driver_id).map((d) => (
                        <option key={d.id} value={d.id}>{d.full_name}</option>
                      ))}
                    </select>
                    <input name="reason" required placeholder={tr(l, "reassignReason")} className="input w-44 py-1 text-xs" />
                    <button className="btn-light py-1 text-xs">{tr(l, "reassign")}</button>
                  </form>
                </td>
              </tr>
            ))}
            {!assigned?.length && <tr><td colSpan={4} className="td text-center text-slate-500">{tr(l, "noData")}</td></tr>}
          </tbody>
        </table>
      </div>

      <div className="card overflow-x-auto p-0">
        <h2 className="border-b px-4 py-3 text-sm font-semibold">{tr(l, "manifest")}</h2>
        <table className="w-full">
          <thead className="border-b bg-slate-50"><tr>
            <th className="th">#</th><th className="th">{tr(l, "driver")}</th><th className="th">{tr(l, "parcels")}</th>
            <th className="th">{tr(l, "status")}</th><th className="th">{tr(l, "delivered")}</th><th className="th">{tr(l, "failed")}</th>
            <th className="th">{tr(l, "created")}</th><th className="th"></th>
          </tr></thead>
          <tbody>
            {(manifests ?? []).map((m: any) => (
              <tr key={m.id} className="border-b last:border-0">
                <td className="td font-mono text-xs">{m.manifest_no}</td>
                <td className="td">{m.drivers?.full_name}</td>
                <td className="td">{m.total_shipments || m.shipment_assignments?.[0]?.count || 0}</td>
                <td className="td"><span className={`rounded px-2 py-0.5 text-xs ${m.status === "closed" ? "bg-slate-200 text-slate-600" : "bg-emerald-100 text-emerald-800"}`}>{m.status === "closed" ? tr(l, "closed") : tr(l, "open")}</span></td>
                <td className="td">{m.delivered_count}</td>
                <td className="td">{m.failed_count}</td>
                <td className="td text-xs" dir="ltr">{new Date(m.created_at).toLocaleString("en-GB", { timeZone: "Asia/Dubai" })}</td>
                <td className="td">
                  {m.status !== "closed" && (
                    <form action={closeManifest}>
                      <input type="hidden" name="id" value={m.id} />
                      <button className="btn-light py-1 text-xs">{tr(l, "closeManifest")}</button>
                    </form>
                  )}
                </td>
              </tr>
            ))}
            {!manifests?.length && <tr><td colSpan={8} className="td text-center text-slate-500">{tr(l, "noData")}</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
