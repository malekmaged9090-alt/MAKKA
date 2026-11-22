"use server";
import { revalidatePath } from "next/cache";
import { z } from "zod";
import { requirePermission } from "@/lib/auth";
export type R = { error?: string; ok?: boolean };
const schema = z.object({ id: z.string().uuid(), full_name: z.string().trim().min(2).max(150),
  phone_alt: z.string().trim().max(20).regex(/^[+0-9 ()-]*$/, "Invalid phone").optional(), notes: z.string().trim().max(1000).optional() });
export async function updateCustomer(_: R | undefined, fd: FormData): Promise<R> {
  const g = await requirePermission("customers.manage"); if (!g.ok) return { error: g.error };
  const p = schema.safeParse(Object.fromEntries(fd)); if (!p.success) return { error: p.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join(" | ") };
  const { error } = await g.supabase.from("customers").update({ full_name: p.data.full_name, phone_alt: p.data.phone_alt || null, notes: p.data.notes || null }).eq("id", p.data.id);
  if (error) return { error: error.message };
  revalidatePath(`/customers/${p.data.id}`); return { ok: true };
}
