import { requirePermission } from "@/lib/auth";
import { templateResponse } from "@/lib/xlsx";
export const dynamic = "force-dynamic";
export async function GET() {
  const g = await requirePermission("shipments.create");
  if (!g.ok) return new Response(g.error, { status: 403 });
  return templateResponse("shipments", "shipments-template.xlsx",
    ["recipient_name", "recipient_phone", "emirate", "area", "address", "service_type", "payment_method", "cod_amount", "goods_value", "parcel_count", "weight_kg", "description", "merchant_reference", "notes"],
    ["Example Customer", "0501234567", "DXB", "", "Street 1, Building 2", "standard", "cod", "150", "150", "1", "1.5", "Clothes", "ORDER-1001", ""]);
}
