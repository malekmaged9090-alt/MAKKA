"use client";
export function PrintButton({ label }: { label: string }) {
  return <button onClick={() => window.print()} className="btn print:hidden">{label}</button>;
}
