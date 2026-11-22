-- =====================================================================
-- MAKKAH DELIVERY - Phase 1 - 0002_seed_and_rls.sql
-- Reference data (idempotent) + Row Level Security
-- Transition rules below are a PROPOSAL: review them with operations.
-- =====================================================================

-- ---------- emirates ----------
insert into emirates (code, name_ar, name_en, sort_order) values
 ('DXB','دبي','Dubai',1), ('AUH','أبوظبي','Abu Dhabi',2), ('SHJ','الشارقة','Sharjah',3),
 ('AJM','عجمان','Ajman',4), ('UAQ','أم القيوين','Umm Al Quwain',5),
 ('RAK','رأس الخيمة','Ras Al Khaimah',6), ('FUJ','الفجيرة','Fujairah',7)
on conflict (code) do nothing;

-- ---------- statuses ----------
insert into shipment_statuses (code,name_ar,name_en,color,sort_order,is_terminal,requires_reason) values
 ('NEW','جديد','New','#64748B',1,false,false),
 ('CONFIRMED','مؤكد','Confirmed','#3B82F6',2,false,false),
 ('PICKUP_REQUESTED','طلب استلام','Pickup Requested','#6366F1',3,false,false),
 ('PICKED_UP','تم الاستلام من التاجر','Picked Up','#8B5CF6',4,false,false),
 ('RECEIVED_AT_HUB','وصلت المركز','Received at Hub','#0EA5E9',5,false,false),
 ('SORTING','قيد الفرز','Sorting','#06B6D4',6,false,false),
 ('READY_FOR_DISPATCH','جاهزة للتوزيع','Ready for Dispatch','#14B8A6',7,false,false),
 ('ASSIGNED_TO_DRIVER','مسندة لسائق','Assigned to Driver','#10B981',8,false,false),
 ('OUT_FOR_DELIVERY','خرجت للتوصيل','Out for Delivery','#F59E0B',9,false,false),
 ('DELIVERED','تم التسليم','Delivered','#16A34A',10,true,false),
 ('DELIVERY_FAILED','فشل التوصيل','Delivery Failed','#DC2626',11,false,true),
 ('RESCHEDULED','أعيدت جدولتها','Rescheduled','#EA580C',12,false,true),
 ('CUSTOMER_UNAVAILABLE','العميل غير متاح','Customer Unavailable','#F97316',13,false,true),
 ('CUSTOMER_REFUSED','رفض العميل','Customer Refused','#B91C1C',14,false,true),
 ('WRONG_ADDRESS','عنوان خاطئ','Wrong Address','#BE123C',15,false,true),
 ('ON_HOLD','معلقة','On Hold','#A16207',16,false,true),
 ('RETURN_TO_HUB','مرتجع للمركز','Return to Hub','#9333EA',17,false,false),
 ('RETURN_TO_MERCHANT','مرتجع للتاجر','Return to Merchant','#7E22CE',18,true,false),
 ('CANCELLED','ملغاة','Cancelled','#475569',19,true,true),
 ('LOST','مفقودة','Lost','#000000',20,true,true),
 ('DAMAGED','تالفة','Damaged','#78350F',21,true,true)
on conflict (code) do nothing;

-- ---------- transitions (proposal) ----------
insert into shipment_status_transitions (from_code,to_code) values
 ('NEW','CONFIRMED'),('NEW','CANCELLED'),('NEW','ON_HOLD'),
 ('CONFIRMED','PICKUP_REQUESTED'),('CONFIRMED','RECEIVED_AT_HUB'),('CONFIRMED','CANCELLED'),('CONFIRMED','ON_HOLD'),
 ('PICKUP_REQUESTED','PICKED_UP'),('PICKUP_REQUESTED','CANCELLED'),('PICKUP_REQUESTED','ON_HOLD'),
 ('PICKED_UP','RECEIVED_AT_HUB'),('PICKED_UP','LOST'),('PICKED_UP','DAMAGED'),
 ('RECEIVED_AT_HUB','SORTING'),('RECEIVED_AT_HUB','READY_FOR_DISPATCH'),('RECEIVED_AT_HUB','ON_HOLD'),('RECEIVED_AT_HUB','LOST'),('RECEIVED_AT_HUB','DAMAGED'),
 ('SORTING','READY_FOR_DISPATCH'),('SORTING','ON_HOLD'),('SORTING','LOST'),('SORTING','DAMAGED'),
 ('READY_FOR_DISPATCH','ASSIGNED_TO_DRIVER'),('READY_FOR_DISPATCH','ON_HOLD'),('READY_FOR_DISPATCH','CANCELLED'),
 ('ASSIGNED_TO_DRIVER','OUT_FOR_DELIVERY'),('ASSIGNED_TO_DRIVER','READY_FOR_DISPATCH'),('ASSIGNED_TO_DRIVER','ON_HOLD'),
 ('OUT_FOR_DELIVERY','DELIVERED'),('OUT_FOR_DELIVERY','DELIVERY_FAILED'),('OUT_FOR_DELIVERY','CUSTOMER_UNAVAILABLE'),
 ('OUT_FOR_DELIVERY','CUSTOMER_REFUSED'),('OUT_FOR_DELIVERY','WRONG_ADDRESS'),('OUT_FOR_DELIVERY','RESCHEDULED'),
 ('DELIVERY_FAILED','READY_FOR_DISPATCH'),('DELIVERY_FAILED','RETURN_TO_HUB'),('DELIVERY_FAILED','ON_HOLD'),
 ('CUSTOMER_UNAVAILABLE','READY_FOR_DISPATCH'),('CUSTOMER_UNAVAILABLE','RETURN_TO_HUB'),('CUSTOMER_UNAVAILABLE','ON_HOLD'),
 ('WRONG_ADDRESS','READY_FOR_DISPATCH'),('WRONG_ADDRESS','RETURN_TO_HUB'),('WRONG_ADDRESS','ON_HOLD'),
 ('RESCHEDULED','READY_FOR_DISPATCH'),('RESCHEDULED','RETURN_TO_HUB'),('RESCHEDULED','ON_HOLD'),
 ('CUSTOMER_REFUSED','RETURN_TO_HUB'),
 ('RETURN_TO_HUB','RETURN_TO_MERCHANT'),('RETURN_TO_HUB','READY_FOR_DISPATCH'),
 ('ON_HOLD','CONFIRMED'),('ON_HOLD','READY_FOR_DISPATCH'),('ON_HOLD','RETURN_TO_HUB'),('ON_HOLD','CANCELLED')
on conflict do nothing;

-- ---------- roles ----------
insert into roles (code,name_ar,name_en) values
 ('super_admin','مدير النظام','Super Admin'),('owner','مالك الشركة','Company Owner'),
 ('ops_manager','مدير العمليات','Operations Manager'),('branch_manager','مدير فرع','Branch Manager'),
 ('dispatcher','موزّع','Dispatcher'),('customer_service','خدمة العملاء','Customer Service'),
 ('accountant','محاسب','Accountant'),('cashier','أمين صندوق','Cashier'),
 ('warehouse','موظف مخزن','Warehouse Staff'),('driver','سائق','Driver'),
 ('merchant_admin','مدير تاجر','Merchant Admin'),('merchant_employee','موظف تاجر','Merchant Employee'),
 ('auditor','مراجع (قراءة فقط)','Auditor / Read Only')
on conflict (code) do nothing;

-- ---------- permissions (Phase 1 set) ----------
insert into permissions (code,description) values
 ('shipments.read_all','View all shipments'), ('shipments.read_own','View own merchant shipments'),
 ('shipments.create','Create shipments'),     ('shipments.update','Edit shipment data'),
 ('shipments.status','Change shipment status'),('shipments.print','Print waybills'),
 ('merchants.read','View merchants'),         ('merchants.manage','Create/edit merchants'),
 ('customers.read','View customers'),         ('customers.manage','Create/edit customers'),
 ('geo.manage','Manage emirates/areas/zones'),('users.manage','Manage users and roles'),
 ('audit.read','View audit logs'),            ('scans.create','Record scans')
on conflict (code) do nothing;

-- role -> permission map
with m(role, perm) as (values
 ('super_admin','*'),('owner','*'),
 ('ops_manager','shipments.read_all'),('ops_manager','shipments.create'),('ops_manager','shipments.update'),('ops_manager','shipments.status'),('ops_manager','shipments.print'),('ops_manager','merchants.read'),('ops_manager','merchants.manage'),('ops_manager','customers.read'),('ops_manager','customers.manage'),('ops_manager','geo.manage'),('ops_manager','scans.create'),('ops_manager','audit.read'),
 ('branch_manager','shipments.read_all'),('branch_manager','shipments.status'),('branch_manager','shipments.print'),('branch_manager','merchants.read'),('branch_manager','customers.read'),('branch_manager','scans.create'),
 ('dispatcher','shipments.read_all'),('dispatcher','shipments.status'),('dispatcher','merchants.read'),('dispatcher','customers.read'),('dispatcher','scans.create'),
 ('customer_service','shipments.read_all'),('customer_service','shipments.create'),('customer_service','shipments.update'),('customer_service','merchants.read'),('customer_service','customers.read'),('customer_service','customers.manage'),
 ('accountant','shipments.read_all'),('accountant','merchants.read'),
 ('cashier','shipments.read_all'),
 ('warehouse','shipments.read_all'),('warehouse','shipments.status'),('warehouse','shipments.print'),('warehouse','scans.create'),
 ('merchant_admin','shipments.read_own'),('merchant_admin','shipments.create'),('merchant_admin','shipments.print'),
 ('merchant_employee','shipments.read_own'),('merchant_employee','shipments.create'),
 ('auditor','shipments.read_all'),('auditor','merchants.read'),('auditor','customers.read'),('auditor','audit.read')
)
insert into role_permissions (role_id, permission_id)
select r.id, p.id from m
join roles r on r.code = m.role
join permissions p on (m.perm = '*' or p.code = m.perm)
on conflict do nothing;

-- ---------- RLS ----------
alter table companies              enable row level security;
alter table branches               enable row level security;
alter table system_settings        enable row level security;
alter table emirates               enable row level security;
alter table cities                 enable row level security;
alter table service_zones          enable row level security;
alter table areas                  enable row level security;
alter table area_aliases           enable row level security;
alter table roles                  enable row level security;
alter table permissions            enable row level security;
alter table role_permissions       enable row level security;
alter table merchants              enable row level security;
alter table profiles               enable row level security;
alter table user_roles             enable row level security;
alter table customers              enable row level security;
alter table customer_addresses     enable row level security;
alter table shipment_statuses      enable row level security;
alter table shipment_status_transitions enable row level security;
alter table serial_counters        enable row level security;   -- no policy: only security-definer fn touches it
alter table shipments              enable row level security;
alter table shipment_parcels       enable row level security;
alter table shipment_status_events enable row level security;
alter table shipment_scans         enable row level security;
alter table barcode_print_logs     enable row level security;
alter table audit_logs             enable row level security;

-- reference data: readable by any signed-in user, managed by geo.manage
do $$ declare t text; begin
  foreach t in array array['emirates','cities','service_zones','areas','area_aliases','shipment_statuses','shipment_status_transitions','roles','branches']
  loop
    execute format('create policy %I on %I for select to authenticated using (true)', t||'_read', t);
  end loop;
  foreach t in array array['cities','service_zones','areas','area_aliases','branches']
  loop
    execute format('create policy %I on %I for all to authenticated using (has_permission(''geo.manage'')) with check (has_permission(''geo.manage''))', t||'_write', t);
  end loop;
end $$;

create policy profiles_self   on profiles for select to authenticated using (id = auth.uid() or has_permission('users.manage'));
create policy profiles_admin  on profiles for all    to authenticated using (has_permission('users.manage')) with check (has_permission('users.manage'));
create policy userroles_read  on user_roles for select to authenticated using (user_id = auth.uid() or has_permission('users.manage'));
create policy userroles_admin on user_roles for all    to authenticated using (has_permission('users.manage')) with check (has_permission('users.manage'));
create policy company_read    on companies for select to authenticated using (id = current_company_id());

create policy merchants_read on merchants for select to authenticated
  using (company_id = current_company_id() and (has_permission('merchants.read') or id = current_merchant_id()));
create policy merchants_write on merchants for all to authenticated
  using (company_id = current_company_id() and has_permission('merchants.manage'))
  with check (company_id = current_company_id() and has_permission('merchants.manage'));

create policy customers_read on customers for select to authenticated
  using (company_id = current_company_id() and has_permission('customers.read'));
create policy customers_write on customers for all to authenticated
  using (company_id = current_company_id() and has_permission('customers.manage'))
  with check (company_id = current_company_id() and has_permission('customers.manage'));
create policy custaddr_read on customer_addresses for select to authenticated
  using (exists (select 1 from customers c where c.id = customer_id and c.company_id = current_company_id()) and has_permission('customers.read'));
create policy custaddr_write on customer_addresses for all to authenticated
  using (has_permission('customers.manage')) with check (has_permission('customers.manage'));

-- shipments: staff see all of their company; merchant users see only their own merchant
create policy shipments_read on shipments for select to authenticated using (
  company_id = current_company_id() and deleted_at is null and (
    has_permission('shipments.read_all')
    or (has_permission('shipments.read_own') and merchant_id = current_merchant_id())));
create policy shipments_insert on shipments for insert to authenticated with check (
  company_id = current_company_id() and has_permission('shipments.create') and (
    has_permission('shipments.read_all') or merchant_id = current_merchant_id()));
create policy shipments_update on shipments for update to authenticated
  using (company_id = current_company_id() and has_permission('shipments.update'))
  with check (company_id = current_company_id() and has_permission('shipments.update'));

create policy parcels_read on shipment_parcels for select to authenticated
  using (exists (select 1 from shipments s where s.id = shipment_id));      -- inherits shipments RLS
create policy events_read on shipment_status_events for select to authenticated
  using (exists (select 1 from shipments s where s.id = shipment_id));
create policy scans_read on shipment_scans for select to authenticated using (has_permission('shipments.read_all'));
create policy scans_insert on shipment_scans for insert to authenticated with check (has_permission('scans.create'));
create policy prints_read on barcode_print_logs for select to authenticated using (has_permission('shipments.read_all'));
create policy prints_insert on barcode_print_logs for insert to authenticated with check (has_permission('shipments.print'));
create policy audit_read on audit_logs for select to authenticated using (has_permission('audit.read'));
