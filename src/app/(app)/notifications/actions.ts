"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
export async function markRead(fd: FormData) {
  const supabase = await createClient();
  await supabase.rpc("mark_notification_read", { p_id: String(fd.get("id")) });
  revalidatePath("/notifications");
}
