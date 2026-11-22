"use client";
import { useActionState } from "react";
import { cancelReturn, completeReturn, inspectReturn, receiveReturn } from "../actions";
import { SubmitButton } from "@/components/SubmitButton";

export function ReturnActions({ id, status, t }: { id: string; status: string; t: Record<string, string> }) {
  const [recvState, recvAction] = useActionState(receiveReturn, undefined);
  const [inspState, inspAction] = useActionState(inspectReturn, undefined);
  const [doneState, doneAction] = useActionState(completeReturn, undefined);
  const [cancelState, cancelAction] = useActionState(cancelReturn, undefined);

  if (status === "returned_to_merchant" || status === "cancelled") {
    return <p className="text-sm text-slate-500">{t.done}</p>;
  }

  return (
    <div className="space-y-4">
      {status === "requested" && (
        <form action={recvAction} className="space-y-2">
          <input type="hidden" name="id" value={id} />
          <input name="note" placeholder={t.note} className="input" />
          {recvState?.error && <p className="text-sm text-red-600">{recvState.error}</p>}
          <SubmitButton label={t.receive} pending="..." />
        </form>
      )}

      {status === "received_at_hub" && (
        <form action={inspAction} className="space-y-2">
          <input type="hidden" name="id" value={id} />
          <label className="label">{t.condition}</label>
          <select name="condition" className="input">
            <option value="good">{t.good}</option>
            <option value="damaged">{t.damaged}</option>
            <option value="missing_items">{t.missingItems}</option>
          </select>
          <input name="note" placeholder={t.note} className="input" />
          {inspState?.error && <p className="text-sm text-red-600">{inspState.error}</p>}
          <SubmitButton label={t.inspect} pending="..." />
        </form>
      )}

      {status === "inspected" && (
        <form action={doneAction}>
          <input type="hidden" name="id" value={id} />
          {doneState?.error && <p className="mb-2 text-sm text-red-600">{doneState.error}</p>}
          <SubmitButton label={t.completeReturn} pending="..." />
        </form>
      )}

      {(status === "requested" || status === "received_at_hub") && (
        <form action={cancelAction} className="space-y-2 border-t pt-3">
          <input type="hidden" name="id" value={id} />
          <input name="reason" required placeholder={t.cancelReturn} className="input" />
          {cancelState?.error && <p className="text-sm text-red-600">{cancelState.error}</p>}
          <button className="btn-light text-red-700">{t.cancelReturn}</button>
        </form>
      )}
    </div>
  );
}
