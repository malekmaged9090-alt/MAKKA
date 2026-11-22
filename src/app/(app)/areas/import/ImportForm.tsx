"use client";
import { useActionState } from "react";
import { previewAreas, commitAreas, type PreviewState } from "./actions";
import { SubmitButton } from "@/components/SubmitButton";

const COLOR: Record<string, string> = { new: "text-emerald-700", exists: "text-slate-500", duplicate: "text-amber-700", error: "text-red-600" };

export function ImportForm() {
  const [prev, previewAction] = useActionState<PreviewState | undefined, FormData>(previewAreas, undefined);
  const [res, commitAction] = useActionState<PreviewState | undefined, FormData>(commitAreas, undefined);
  const rows = prev?.rows ?? [];
  const count = (s: string) => rows.filter((r) => r.status === s).length;
  const toInsert = rows.filter((r) => r.status === "new");
  return (
    <div className="space-y-4">
      <form action={previewAction} className="card flex flex-wrap items-end gap-3">
        <div><label className="label">Excel (.xlsx)</label><input type="file" name="file" accept=".xlsx" required className="input" /></div>
        <SubmitButton label="معاينة / Preview" pending="..." />
        <a href="/areas/import/template" className="btn-light">قالب / Template</a>
      </form>
      {prev?.error && <p className="text-sm text-red-600">{prev.error}</p>}
      {res?.error && <p className="text-sm text-red-600">{res.error}</p>}
      {res?.done && <p className="rounded bg-emerald-50 p-3 text-sm text-emerald-800">تمت إضافة {res.done.inserted} منطقة / {res.done.inserted} areas added</p>}
      {rows.length > 0 && !res?.done && (
        <div className="space-y-3">
          <p className="text-sm">جديد/new: <b>{count("new")}</b> · موجود/exists: {count("exists")} · مكرر/dup: {count("duplicate")} · أخطاء/errors: <b className="text-red-600">{count("error")}</b> · للمراجعة/review: {toInsert.filter((r) => r.needs_review).length}</p>
          <div className="card max-h-[28rem] overflow-auto p-0">
            <table className="w-full"><thead className="sticky top-0 border-b bg-slate-50"><tr>{["#", "Emirate", "English", "العربي", "Zone", "Review", "Status"].map((h) => <th key={h} className="th">{h}</th>)}</tr></thead>
              <tbody>{rows.map((r) => (
                <tr key={r.line} className="border-b last:border-0">
                  <td className="td">{r.line}</td><td className="td">{r.emirate_code}</td><td className="td" dir="ltr">{r.name_en}</td><td className="td">{r.name_ar}</td><td className="td">{r.zone}</td>
                  <td className="td">{r.needs_review ? "⚑" : ""}</td>
                  <td className={`td ${COLOR[r.status]}`}>{r.status}{r.messages.length ? ` — ${r.messages.join("; ")}` : ""}</td>
                </tr>))}</tbody></table>
          </div>
          {count("error") > 0 && <p className="text-sm text-red-600">أصلح الأخطاء في الملف وأعد المعاينة؛ الصفوف الخاطئة لن تُستورد. / Fix errors and re-preview; error rows are not imported.</p>}
          {toInsert.length > 0 && count("error") === 0 && (
            <form action={commitAction}>
              <input type="hidden" name="rows" value={JSON.stringify(toInsert.map(({ line, emirate_id, name_en, name_ar, zone, needs_review }) => ({ line, emirate_id, name_en, name_ar, zone, needs_review })))} />
              <SubmitButton label={`استيراد ${toInsert.length} / Import ${toInsert.length}`} pending="..." />
            </form>)}
        </div>)}
    </div>
  );
}
