import { getLocale, tr } from "@/lib/i18n";
import { BulkScanForm } from "./BulkScanForm";

export const dynamic = "force-dynamic";

export default async function BulkScanPage() {
  const l = await getLocale();
  const t: Record<string, string> = {
    scanType: tr(l, "scanType"), receiveAtHub: tr(l, "receiveAtHub"), sorting: tr(l, "sorting"),
    loadToDriver: tr(l, "loadToDriver"), returnReceive: tr(l, "returnReceive"), returnToMerchant: tr(l, "returnToMerchant"),
    codes: tr(l, "codes"), onePerLine: tr(l, "onePerLine"), note: tr(l, "note"), runScan: tr(l, "runScan"),
    scanResults: tr(l, "scanResults"), scanOk: tr(l, "scanOk"), scanDuplicates: tr(l, "scanDuplicates"),
    scanNotFound: tr(l, "scanNotFound"), scanRejected: tr(l, "scanRejected"), serial: tr(l, "serial"),
    status: tr(l, "status"), required: tr(l, "required"),
  };
  return (
    <div className="max-w-4xl space-y-4">
      <div>
        <h1 className="text-xl font-bold">{tr(l, "bulkScan")}</h1>
        <p className="text-sm text-slate-500">{tr(l, "bulkScanHint")}</p>
      </div>
      <BulkScanForm t={t} />
    </div>
  );
}
