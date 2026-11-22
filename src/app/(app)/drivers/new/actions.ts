"use server";
import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

const schema = z.object({
  full_name: z.string().trim().min(2).max(150),
  phone: z.string().trim().regex(/^[+0-9 ()-]{7,20}$/, "Invalid phone"),
  phone_alt: z.string().trim().max(20).optional().or(z.literal("")),
  email: z.string().trim().email().optional().or(z.literal("")),
  emirate_id: z.string().uuid(),
  area_id: z.string().uuid().optional().or(z.literal("")),
  employee_no: z.string().trim().max(50).optional().or(z.literal("")),
  hired_on: z.string().optional().or(z.literal("")),
  contract_type: z.string().trim().max(50).optional().or(z.literal("")),
  license_type: z.string().trim().max(50).optional().or(z.literal("")),
  license_expiry: z.string().optional().or(z.literal("")),
  vehicle_type: z.string().trim().max(50).optional().or(z.literal("")),
  plate_no: z.string().trim().max(30).optional().or(z.literal("")),
  commission_per_delivery: z.coerce.number().min(0).max(9999).default(0),
});

export async function createDriver(_: { error?: string } | undefined, fd: FormData) {
  const parsed = schema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { error: parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join(" | ") };
  const v = parsed.data;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Not signed in" };
  const { data: profile } = await supabase.from("profiles").select("company_id").eq("id", user.id).single();
  if (!profile) return { error: "Profile not found" };

  const { data: driver, error } = await supabase.from("drivers").insert({
    company_id: profile.company_id,
    full_name: v.full_name,
    phone: v.phone,
    phone_alt: v.phone_alt || null,
    email: v.email || null,
    emirate_id: v.emirate_id,
    employee_no: v.employee_no || null,
    hired_on: v.hired_on || null,
    contract_type: v.contract_type || null,
    license_type: v.license_type || null,
    license_expiry: v.license_expiry || null,
    commission_per_delivery: v.commission_per_delivery,
    status: "offline",
  }).select("id").single();
  if (error) return { error: error.message };

  if (v.area_id) {
    const { error: covErr } = await supabase.from("driver_area_assignments").insert({ driver_id: driver.id, area_id: v.area_id });
    if (covErr) return { error: `driver created, coverage failed: ${covErr.message}` };
  } else {
    const { error: covErr } = await supabase.from("driver_area_assignments").insert({ driver_id: driver.id, emirate_id: v.emirate_id });
    if (covErr) return { error: `driver created, coverage failed: ${covErr.message}` };
  }

  if (v.vehicle_type && v.plate_no) {
    await supabase.from("vehicles").insert({
      company_id: profile.company_id, driver_id: driver.id, vehicle_type: v.vehicle_type, plate_no: v.plate_no,
    });
  }

  redirect("/drivers");
}
