import { getLocale, tr } from "@/lib/i18n";
import { ImportForm } from "./ImportForm";
export default async function ImportAreas() {
  const l = await getLocale();
  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">{tr(l, "importAreas")}</h1>
      <p className="text-sm text-slate-600">الأعمدة: emirate (الرمز أو الاسم) · name_en · name_ar · zone (اختياري) · needs_review (اختياري). الصفوف الموجودة تُتخطّى، والأسماء المشكوك فيها تُعلَّم للمراجعة. / Columns: emirate, name_en, name_ar, optional zone, needs_review. Existing rows are skipped; doubtful names are flagged.</p>
      <ImportForm />
    </div>
  );
}
