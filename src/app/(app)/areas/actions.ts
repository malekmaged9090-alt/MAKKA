"use server";
import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/auth";
// Disable instead of delete (design rule). Flags only; names are never edited here.
export async function toggleArea(fd: FormData) {
  const g = await requirePermission("geo.manage");
  if (!g.ok) return;
  const id = String(fd.get("id") ?? ""), field = String(fd.get("field") ?? "");
  if (!["is_active", "needs_review", "is_covered"].includes(field)) return;
  const { data: cur } = await g.supabase.from("areas").select(field).eq("id", id).single();
  if (!cur) return;
  const curVal = (cur as unknown as Record<string, boolean>)[field];
  await g.supabase.from("areas").update({ [field]: !curVal, updated_at: new Date().toISOString() }).eq("id", id);
  revalidatePath("/areas");
}
