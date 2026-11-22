import Link from "next/link";
import { getLocale, tr } from "@/lib/i18n";
import { createClient } from "@/lib/supabase/server";
import { logout, toggleLocale } from "../actions";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const l = await getLocale();
  const supabase = await createClient();
  const { data: perms } = await supabase.rpc("my_permissions");
  const has = new Set<string>((perms as string[] | null) ?? []);
  type Item = [string, string, string?];   // href, i18n key, required permission
  const all: { title: string; items: Item[] }[] = [
    { title: "", items: [["/", "dashboard"], ["/shipments", "shipments", "shipments.read_all"], ["/shipments/new", "newShipment", "shipments.create"], ["/shipments/import", "importShipments", "shipments.create"]] },
    { title: l === "ar" ? "العمليات" : "Operations", items: [["/dispatch", "dispatch", "dispatch.assign"], ["/scan", "scan", "scans.create"], ["/scan/bulk", "bulkScan", "scans.bulk"], ["/returns", "returns", "returns.read"], ["/follow-up", "followUp", "shipments.read_all"], ["/driver", "driverApp", "driver.app"]] },
    { title: l === "ar" ? "الشركاء والبيانات" : "Partners & data", items: [["/merchants", "merchants", "merchants.read"], ["/customers", "customers", "customers.read"], ["/drivers", "drivers", "drivers.read"], ["/areas", "areas", "geo.manage"]] },
    { title: l === "ar" ? "المالية" : "Finance", items: [["/finance", "finance", "finance.read"], ["/finance/settlements", "settlements", "finance.read"], ["/reports", "reports", "reports.read"], ["/notifications", "notifications", "notifications.read"]] },
    { title: l === "ar" ? "الإدارة" : "Admin", items: [["/users", "users", "users.manage"]] },
  ];
  const groups = all.map((g) => ({ title: g.title, items: g.items.filter((i) => !i[2] || has.has(i[2])).map((i) => [i[0], i[1]] as [string, string]) })).filter((g) => g.items.length);
  return (
    <div className="flex min-h-screen">
      <aside className="w-60 shrink-0 bg-slate-900 p-4 text-slate-100 print:hidden">
        <Link href="/" className="mb-6 flex items-center gap-2">
          <div className="flex h-9 w-9 items-center justify-center rounded bg-emerald-600 font-bold">M</div>
          <div className="text-sm font-bold leading-tight">MAKKAH<br />DELIVERY</div>
        </Link>
        <nav className="space-y-4">
          {groups.map((g, i) => (
            <div key={i}>
              {g.title && <div className="mb-1 px-3 text-[10px] uppercase tracking-wider text-slate-500">{g.title}</div>}
              <div className="space-y-0.5">
                {g.items.map(([href, key]) => (
                  <Link key={href} href={href} className="block rounded px-3 py-2 text-sm text-slate-200 hover:bg-slate-800 hover:text-white">
                    {tr(l, key)}
                  </Link>
                ))}
              </div>
            </div>
          ))}
        </nav>
        <div className="mt-8 space-y-2">
          <form action={toggleLocale}><button className="w-full rounded border border-slate-600 px-3 py-1.5 text-xs">{tr(l, "locale")}</button></form>
          <form action={logout}><button className="w-full rounded border border-slate-600 px-3 py-1.5 text-xs">{tr(l, "logout")}</button></form>
        </div>
      </aside>
      <main className="min-w-0 flex-1 overflow-x-auto p-4 md:p-6">{children}</main>
    </div>
  );
}
