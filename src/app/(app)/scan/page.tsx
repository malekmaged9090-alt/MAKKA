import Link from "next/link";
import { getLocale, tr } from "@/lib/i18n";
import { ScanForm } from "./ScanForm";
export default async function Scan() {
  const l = await getLocale();
  return (
    <div className="max-w-xl space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">{tr(l, "scan")}</h1>
        <Link href="/scan/bulk" className="btn">{tr(l, "bulkScan")}</Link>
      </div>
      <ScanForm hint={tr(l, "scanHint")} notFound={tr(l, "notFound")} />
    </div>
  );
}
