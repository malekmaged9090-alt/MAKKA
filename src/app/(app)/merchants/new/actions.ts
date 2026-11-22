"use server";
import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
const schema = z.object({ name: z.string().trim().min(2).max(150), trade_name: z.string().trim().max(150).optional(), phone: z.string().trim().max(20).optional(), email: z.string().trim().email().optional().or(z.literal("")) });
export async function createMerchant(_: { error?: string } | undefined, fd: FormData) {
  const p = schema.safeParse(Object.fromEntries(fd));
  if (!p.success) return { error: p.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join(" | ") };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from("profiles").select("company_id").eq("id", user!.id).single();
  const { error } = await supabase.from("merchants").insert({ ...p.data, email: p.data.email || null, company_id: profile!.company_id, created_by: user!.id });
  if (error) return { error: error.message };
  redirect("/merchants");
}
