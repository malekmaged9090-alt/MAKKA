"use client";
import { useActionState } from "react";
import { scanLookup } from "./actions";

export function ScanForm({ hint, notFound }: { hint: string; notFound: string }) {
  const [state, action] = useActionState(scanLookup, undefined);
  return (
    <form action={action} className="card max-w-xl space-y-3">
      {/* USB/Bluetooth scanners type the code then press Enter, which submits this form */}
      <input name="code" autoFocus autoComplete="off" placeholder={hint} className="input font-mono text-lg" dir="ltr" />
      {state?.error && <p className="text-sm text-red-600">{state.error === "notFound" ? notFound : state.error}</p>}
    </form>
  );
}
