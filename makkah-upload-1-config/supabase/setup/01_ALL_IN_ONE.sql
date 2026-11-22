-- =====================================================================
-- MAKKAH DELIVERY - ALL-IN-ONE database setup (generated: do not edit; run "npm run build:setup")
-- Contains: 0001_core_schema.sql, 0002_seed_and_rls.sql, 0003_drivers_dispatch.sql, 0004_finance_cod.sql, 0005_returns_ops.sql, 0006_reports_notifications.sql, 0007_security_fixes.sql, 0008_hardening.sql, 0009_users_admin.sql
-- Runs as ONE transaction: if anything fails, nothing is applied.
-- Run on an EMPTY public schema (new project, or after 00_RESET_public_schema.sql).
-- =====================================================================
begin;

-- ############ 0001_core_schema.sql ############
-- =====================================================================
-- MAKKAH DELIVERY - Phase 1 - 0001_core_schema.sql
-- Core tables: company, geography, users/permissions, merchants,
-- customers, shipments, serial numbers, lifecycle, scans, audit.
-- Money = NUMERIC(12,2) only. No float anywhere.
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- generic helpers ----------
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ---------- company / branches ----------
create table companies (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                 -- serial prefix, e.g. MKK
  name_ar text not null,
  name_en text not null,
  currency char(3) not null default 'AED',
  timezone text not null default 'Asia/Dubai',
  tax_number text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table branches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  name_ar text not null,
  name_en text not null,
  kind text not null default 'hub' check (kind in ('branch','hub','sorting','warehouse','pickup_point')),
  emirate_id uuid,                            -- FK added below
  address text,
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table system_settings (
  company_id uuid not null references companies(id),
  key text not null,
  value jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (company_id, key)
);

-- ---------- geography (all editable, never hard-coded) ----------
create table emirates (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_ar text not null,
  name_en text not null,
  is_active boolean not null default true,
  sort_order int not null default 0
);
alter table branches add constraint branches_emirate_fk foreign key (emirate_id) references emirates(id);

create table cities (
  id uuid primary key default gen_random_uuid(),
  emirate_id uuid not null references emirates(id),
  name_ar text not null,
  name_en text not null,
  is_active boolean not null default true,
  unique (emirate_id, name_en)
);

create table service_zones (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  name text not null,
  is_active boolean not null default true,
  unique (company_id, name)
);

create table areas (
  id uuid primary key default gen_random_uuid(),
  emirate_id uuid not null references emirates(id),
  city_id uuid references cities(id),
  service_zone_id uuid references service_zones(id),
  name_ar text not null,
  name_en text not null,
  is_covered boolean not null default true,    -- inside company service coverage
  is_active boolean not null default true,     -- disable instead of delete
  needs_review boolean not null default false, -- flag uncertain names for admin review
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (emirate_id, name_en)
);
create index areas_emirate_idx on areas(emirate_id);
create index areas_zone_idx on areas(service_zone_id);

create table area_aliases (
  id uuid primary key default gen_random_uuid(),
  area_id uuid not null references areas(id),
  alias text not null,
  unique (area_id, alias)
);

-- ---------- users, roles, permissions ----------
create table roles (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_ar text not null,
  name_en text not null
);
create table permissions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  description text
);
create table role_permissions (
  role_id uuid not null references roles(id) on delete cascade,
  permission_id uuid not null references permissions(id) on delete cascade,
  primary key (role_id, permission_id)
);

create table merchants (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  merchant_no bigint generated always as identity,
  name text not null,
  trade_name text,
  license_no text,
  phone text,
  phone_alt text,
  email text,
  emirate_id uuid references emirates(id),
  area_id uuid references areas(id),
  address text,
  contact_person text,
  contract_start date,
  status text not null default 'active' check (status in ('active','suspended','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid
);
create index merchants_name_idx on merchants(lower(name));

create table profiles (                         -- one row per auth user
  id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid not null references companies(id),
  full_name text not null,
  phone text,
  locale text not null default 'ar' check (locale in ('ar','en')),
  branch_id uuid references branches(id),
  merchant_id uuid references merchants(id),    -- set for merchant users only
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table user_roles (
  user_id uuid not null references profiles(id) on delete cascade,
  role_id uuid not null references roles(id),
  primary key (user_id, role_id)
);

create or replace function has_permission(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from profiles pr
    join user_roles ur on ur.user_id = pr.id
    join role_permissions rp on rp.role_id = ur.role_id
    join permissions pm on pm.id = rp.permission_id
    where pr.id = auth.uid() and pr.is_active and pm.code = p
  );
$$;
create or replace function current_company_id() returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from profiles where id = auth.uid();
$$;
create or replace function current_merchant_id() returns uuid
language sql stable security definer set search_path = public as $$
  select merchant_id from profiles where id = auth.uid();
$$;

-- ---------- customers (recipients) ----------
create table customers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  full_name text not null,
  phone text not null,
  phone_alt text,
  notes text,
  delivered_count int not null default 0,
  refused_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid
);
create index customers_phone_idx on customers(phone);          -- repeat customers found, never auto-merged
create index customers_name_idx on customers(lower(full_name));

create table customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id),
  emirate_id uuid not null references emirates(id),
  area_id uuid references areas(id),
  street text, building_name text, building_no text, unit_no text, floor text,
  landmark text, map_url text,
  latitude numeric(9,6), longitude numeric(9,6),
  delivery_instructions text,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index customer_addresses_customer_idx on customer_addresses(customer_id);

-- ---------- lifecycle definitions ----------
create table shipment_statuses (
  code text primary key,
  name_ar text not null,
  name_en text not null,
  color text not null,
  sort_order int not null,
  is_terminal boolean not null default false,
  requires_reason boolean not null default false
);
create table shipment_status_transitions (
  from_code text not null references shipment_statuses(code),
  to_code text not null references shipment_statuses(code),
  required_permission text,                      -- null = any permitted operator
  primary key (from_code, to_code)
);

-- ---------- serial counters + shipments ----------
create table serial_counters (
  company_id uuid not null references companies(id),
  year int not null,
  last_value bigint not null default 0,
  primary key (company_id, year)
);

create table shipments (
  id uuid primary key default gen_random_uuid(),      -- immutable internal ID
  company_id uuid not null references companies(id),
  serial_number text not null,                        -- MKK-2026-00000001
  tracking_number text not null,                      -- public tracking no.
  tracking_token text not null,                       -- unguessable random token for QR/public link
  awb_number text,
  merchant_id uuid not null references merchants(id),
  merchant_reference text,
  idempotency_key text,                               -- stops double-submit creating 2 shipments

  customer_id uuid references customers(id),
  recipient_name text not null,                       -- snapshot at creation
  recipient_phone text not null,
  delivery_address_id uuid references customer_addresses(id),
  delivery_emirate_id uuid not null references emirates(id),
  delivery_area_id uuid references areas(id),
  delivery_address_text text not null,
  pickup_address_text text,

  service_type text not null check (service_type in
    ('same_day','next_day','standard','express','scheduled','return_pickup','exchange','document')),
  priority smallint not null default 0,
  description text,
  parcel_count int not null default 1 check (parcel_count > 0),
  weight_kg numeric(8,3) check (weight_kg is null or weight_kg >= 0),
  goods_value numeric(12,2) not null default 0 check (goods_value >= 0),

  payment_method text not null default 'cod' check (payment_method in ('cash','card','online_paid','prepaid','cod')),
  cod_amount numeric(12,2) not null default 0 check (cod_amount >= 0),
  delivery_fee numeric(12,2) not null default 0 check (delivery_fee >= 0),   -- snapshot from rate card (Phase 3)
  extra_fee numeric(12,2) not null default 0 check (extra_fee >= 0),
  tax_amount numeric(12,2) not null default 0 check (tax_amount >= 0),
  payment_status text not null default 'pending' check (payment_status in ('pending','collected','paid','refunded')),

  status_code text not null default 'NEW' references shipment_statuses(code),
  current_branch_id uuid references branches(id),
  expected_delivery_at timestamptz,
  notes text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid,
  deleted_at timestamptz,
  unique (serial_number),
  unique (tracking_number),
  unique (tracking_token),
  unique (company_id, idempotency_key)
);
create index shipments_merchant_idx on shipments(merchant_id, created_at desc);
create index shipments_status_idx on shipments(status_code);
create index shipments_area_idx on shipments(delivery_area_id);
create index shipments_phone_idx on shipments(recipient_phone);
create index shipments_mref_idx on shipments(merchant_id, merchant_reference);
create index shipments_created_idx on shipments(created_at desc);

create table shipment_parcels (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  parcel_serial text not null unique,                 -- MKK-2026-00000001-P01
  weight_kg numeric(8,3),
  created_at timestamptz not null default now()
);

create table shipment_status_events (                 -- append-only timeline
  id bigint generated always as identity primary key,
  shipment_id uuid not null references shipments(id),
  from_code text references shipment_statuses(code),
  to_code text not null references shipment_statuses(code),
  changed_by uuid,
  branch_id uuid references branches(id),
  reason text,
  note text,
  attachment_path text,
  created_at timestamptz not null default now()
);
create index status_events_shipment_idx on shipment_status_events(shipment_id, created_at);

create table shipment_scans (
  id bigint generated always as identity primary key,
  shipment_id uuid references shipments(id),
  scanned_code text not null,
  scan_context text not null check (scan_context in ('lookup','receive','sort','dispatch','delivery','return')),
  scanned_by uuid,
  branch_id uuid,
  device text,
  created_at timestamptz not null default now()
);
create index scans_shipment_idx on shipment_scans(shipment_id, created_at);

create table barcode_print_logs (
  id bigint generated always as identity primary key,
  shipment_id uuid not null references shipments(id),
  printed_by uuid,
  format text not null check (format in ('100x150','a4')),
  is_reprint boolean not null default false,
  created_at timestamptz not null default now()
);

create table audit_logs (
  id bigint generated always as identity primary key,
  table_name text not null,
  record_id text,
  action text not null,
  old_data jsonb,
  new_data jsonb,
  actor uuid,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- SERIAL NUMBER (atomic, concurrency-safe)
-- INSERT .. ON CONFLICT DO UPDATE takes a row lock, so concurrent
-- transactions are serialized and can never receive the same value.
-- If the surrounding transaction rolls back, the counter rolls back too
-- (no number is ever consumed without a stored shipment).
-- =====================================================================
create or replace function next_shipment_serial(p_company uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_year int := extract(year from (now() at time zone 'Asia/Dubai'))::int;
  v_next bigint;
  v_prefix text;
begin
  select code into v_prefix from companies where id = p_company;
  if v_prefix is null then raise exception 'unknown company %', p_company; end if;
  insert into serial_counters (company_id, year, last_value) values (p_company, v_year, 1)
  on conflict (company_id, year) do update set last_value = serial_counters.last_value + 1
  returning last_value into v_next;
  return format('%s-%s-%s', v_prefix, v_year, lpad(v_next::text, 8, '0'));
end $$;

-- fill identifiers on insert, regardless of what the client sends
create or replace function shipments_before_insert() returns trigger language plpgsql as $$
begin
  new.serial_number    := next_shipment_serial(new.company_id);
  new.tracking_number  := new.serial_number;                       -- public tracking no. = serial
  new.tracking_token   := encode(gen_random_bytes(16), 'hex');     -- 128-bit unguessable
  new.status_code      := 'NEW';
  return new;
end $$;
create trigger trg_shipments_before_insert before insert on shipments
  for each row execute function shipments_before_insert();

-- immutable fields + status only via change_shipment_status()
create or replace function shipments_before_update() returns trigger language plpgsql as $$
begin
  if new.id <> old.id or new.serial_number <> old.serial_number
     or new.tracking_number <> old.tracking_number or new.tracking_token <> old.tracking_token
     or new.company_id <> old.company_id or new.created_at <> old.created_at then
    raise exception 'immutable shipment field cannot be changed';
  end if;
  if new.status_code <> old.status_code and coalesce(current_setting('app.status_via_fn', true), '') <> 'on' then
    raise exception 'status must be changed through change_shipment_status()';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_shipments_before_update before update on shipments
  for each row execute function shipments_before_update();

-- parcel serials: base serial + -P01, -P02 ...
create or replace function create_parcels(p_shipment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select serial_number, parcel_count into s from shipments where id = p_shipment;
  insert into shipment_parcels (shipment_id, parcel_serial)
  select p_shipment, s.serial_number || '-P' || lpad(g::text, 2, '0')
  from generate_series(1, s.parcel_count) g
  on conflict (parcel_serial) do nothing;
end $$;

-- ---------- controlled status change ----------
create or replace function change_shipment_status(
  p_shipment uuid, p_to text, p_reason text default null,
  p_note text default null, p_branch uuid default null, p_attachment text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_from text; v_perm text; v_req boolean;
begin
  select status_code into v_from from shipments where id = p_shipment for update;
  if v_from is null then raise exception 'shipment not found'; end if;
  select required_permission into v_perm from shipment_status_transitions
   where from_code = v_from and to_code = p_to;
  if not found then raise exception 'transition % -> % is not allowed', v_from, p_to; end if;
  if v_perm is not null and not has_permission(v_perm) then
    raise exception 'permission % required', v_perm;
  end if;
  select requires_reason into v_req from shipment_statuses where code = p_to;
  if v_req and coalesce(trim(p_reason), '') = '' then
    raise exception 'a reason is required for status %', p_to;
  end if;
  perform set_config('app.status_via_fn', 'on', true);
  update shipments set status_code = p_to, current_branch_id = coalesce(p_branch, current_branch_id)
   where id = p_shipment;
  insert into shipment_status_events (shipment_id, from_code, to_code, changed_by, branch_id, reason, note, attachment_path)
  values (p_shipment, v_from, p_to, auth.uid(), p_branch, p_reason, p_note, p_attachment);
end $$;

-- first event when a shipment is created
create or replace function shipments_after_insert() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into shipment_status_events (shipment_id, from_code, to_code, changed_by, note)
  values (new.id, null, 'NEW', new.created_by, 'created');
  perform create_parcels(new.id);
  return new;
end $$;
create trigger trg_shipments_after_insert after insert on shipments
  for each row execute function shipments_after_insert();

-- ---------- append-only protection ----------
create or replace function forbid_change() returns trigger language plpgsql as $$
begin raise exception '% is append-only', tg_table_name; end $$;
create trigger trg_events_ro  before update or delete on shipment_status_events for each row execute function forbid_change();
create trigger trg_audit_ro   before update or delete on audit_logs             for each row execute function forbid_change();
create trigger trg_scans_ro   before update or delete on shipment_scans         for each row execute function forbid_change();
create trigger trg_prints_ro  before update or delete on barcode_print_logs     for each row execute function forbid_change();

-- no hard delete of shipments or areas used by shipments
create or replace function forbid_delete() returns trigger language plpgsql as $$
begin raise exception 'deleting from % is not allowed; deactivate instead', tg_table_name; end $$;
create trigger trg_shipments_nodel before delete on shipments for each row execute function forbid_delete();
create trigger trg_areas_nodel     before delete on areas     for each row execute function forbid_delete();

-- ---------- generic audit trigger ----------
create or replace function audit_row() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into audit_logs (table_name, record_id, action, old_data, new_data, actor)
  values (tg_table_name,
          coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id', ''),
          tg_op,
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,
          auth.uid());
  return null;
end $$;
create trigger trg_audit_shipments  after insert or update or delete on shipments  for each row execute function audit_row();
create trigger trg_audit_merchants  after insert or update or delete on merchants  for each row execute function audit_row();
create trigger trg_audit_customers  after insert or update or delete on customers  for each row execute function audit_row();
create trigger trg_audit_areas      after insert or update or delete on areas      for each row execute function audit_row();
create trigger trg_audit_userroles  after insert or update or delete on user_roles for each row execute function audit_row();

-- updated_at triggers
create trigger trg_merchants_upd before update on merchants for each row execute function set_updated_at();
create trigger trg_customers_upd before update on customers for each row execute function set_updated_at();
create trigger trg_areas_upd     before update on areas     for each row execute function set_updated_at();
create trigger trg_profiles_upd  before update on profiles  for each row execute function set_updated_at();

-- ############ 0002_seed_and_rls.sql ############
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

-- ############ 0003_drivers_dispatch.sql ############
-- =====================================================================
-- MAKKAH DELIVERY - Phase 2 - 0003_drivers_dispatch.sql
-- Drivers, vehicles, coverage, dispatch manifests, assignments,
-- proof of delivery, failed attempts, public tracking.
-- ALSO FIXES a Phase 1 gap: change_shipment_status() had no general
-- permission check, so any signed-in user could call it. It is now a
-- guarded wrapper over an internal function that clients cannot call.
-- =====================================================================

-- ---------- hardening of Phase 1 internals ----------
create or replace function shipments_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.serial_number   := next_shipment_serial(new.company_id);
  new.tracking_number := new.serial_number;
  new.tracking_token  := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');  -- 244 random bits
  new.status_code     := 'NEW';
  return new;
end $$;
revoke execute on function next_shipment_serial(uuid) from public, anon, authenticated;
revoke execute on function create_parcels(uuid)       from public, anon, authenticated;

-- ---------- permissions / roles ----------
insert into permissions (code,description) values
 ('drivers.read','View drivers'),('drivers.manage','Create/edit drivers and coverage'),
 ('dispatch.assign','Assign shipments to drivers'),('dispatch.override_area','Assign outside driver coverage'),
 ('driver.app','Use the driver app')
on conflict (code) do nothing;

with m(role, perm) as (values
 ('ops_manager','drivers.read'),('ops_manager','drivers.manage'),('ops_manager','dispatch.assign'),('ops_manager','dispatch.override_area'),
 ('branch_manager','drivers.read'),('branch_manager','dispatch.assign'),
 ('dispatcher','drivers.read'),('dispatcher','dispatch.assign'),
 ('customer_service','drivers.read'),('accountant','drivers.read'),('auditor','drivers.read'),
 ('driver','driver.app')
)
insert into role_permissions (role_id, permission_id)
select r.id, p.id from m join roles r on r.code = m.role join permissions p on p.code = m.perm
on conflict do nothing;
insert into role_permissions (role_id, permission_id)          -- owner / super_admin get every new permission
select r.id, p.id from roles r cross join permissions p where r.code in ('super_admin','owner')
on conflict do nothing;

-- ---------- drivers ----------
create table drivers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  driver_no bigint generated always as identity,
  user_id uuid unique references profiles(id),
  full_name text not null,
  phone text not null,
  phone_alt text,
  email text,
  emirate_id uuid references emirates(id),
  branch_id uuid references branches(id),
  employee_no text,
  hired_on date,
  status text not null default 'offline' check (status in ('available','busy','on_delivery','offline','on_break','suspended','inactive')),
  contract_type text,
  license_type text,
  license_expiry date,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid
);
create index drivers_company_idx on drivers(company_id, status);

create table vehicles (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  driver_id uuid references drivers(id),
  vehicle_type text not null,
  plate_no text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, plate_no)
);

create table driver_area_assignments (        -- coverage: a whole emirate OR one area
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references drivers(id) on delete cascade,
  emirate_id uuid references emirates(id),
  area_id uuid references areas(id),
  check ((emirate_id is not null) <> (area_id is not null)),
  unique (driver_id, emirate_id, area_id)
);

-- ---------- manifests / assignments ----------
create table doc_counters (
  company_id uuid not null references companies(id),
  kind text not null,
  year int not null,
  last_value bigint not null default 0,
  primary key (company_id, kind, year)
);
create or replace function next_doc_no(p_company uuid, p_kind text) returns text
language plpgsql security definer set search_path = public as $$
declare v_year int := extract(year from (now() at time zone 'Asia/Dubai'))::int; v_next bigint;
begin
  insert into doc_counters (company_id, kind, year, last_value) values (p_company, p_kind, v_year, 1)
  on conflict (company_id, kind, year) do update set last_value = doc_counters.last_value + 1
  returning last_value into v_next;
  return format('%s-%s-%s', p_kind, v_year, lpad(v_next::text, 6, '0'));
end $$;
revoke execute on function next_doc_no(uuid, text) from public, anon, authenticated;

create table dispatch_manifests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  manifest_no text not null unique,
  driver_id uuid not null references drivers(id),
  created_by uuid,
  created_at timestamptz not null default now()
);

create table shipment_assignments (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  driver_id uuid not null references drivers(id),
  manifest_id uuid references dispatch_manifests(id),
  assigned_by uuid,
  assigned_at timestamptz not null default now(),
  accepted_at timestamptz,
  unassigned_at timestamptz,
  is_current boolean not null default true
);
create unique index one_current_assignment on shipment_assignments(shipment_id) where is_current;
create index assignments_driver_idx on shipment_assignments(driver_id) where is_current;

create table proof_of_delivery (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null unique references shipments(id),
  driver_id uuid not null references drivers(id),
  delivered_at timestamptz not null default now(),
  receiver_name text,
  collected_amount numeric(12,2) not null default 0 check (collected_amount >= 0),
  collected_method text check (collected_method in ('cash','card','online_paid','prepaid','cod')),
  otp_verified boolean not null default false,
  signature_path text,
  photo_path text,
  note text
);

create table failed_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  driver_id uuid not null references drivers(id),
  attempt_no int not null,
  outcome text not null,
  reason text not null,
  note text,
  reschedule_at timestamptz,
  created_at timestamptz not null default now(),
  unique (shipment_id, attempt_no)
);

create trigger trg_drivers_upd before update on drivers for each row execute function set_updated_at();
create trigger trg_audit_drivers after insert or update or delete on drivers for each row execute function audit_row();
create trigger trg_pod_ro   before update or delete on proof_of_delivery        for each row execute function forbid_change();
create trigger trg_fail_ro  before update or delete on failed_delivery_attempts for each row execute function forbid_change();

-- ---------- status engine: internal + guarded wrapper ----------
create or replace function _change_status(
  p_shipment uuid, p_to text, p_reason text default null, p_note text default null,
  p_branch uuid default null, p_attachment text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_from text; v_req boolean;
begin
  select status_code into v_from from shipments where id = p_shipment for update;
  if v_from is null then raise exception 'shipment not found'; end if;
  if not exists (select 1 from shipment_status_transitions where from_code = v_from and to_code = p_to) then
    raise exception 'transition % -> % is not allowed', v_from, p_to;
  end if;
  select requires_reason into v_req from shipment_statuses where code = p_to;
  if v_req and coalesce(trim(p_reason), '') = '' then raise exception 'a reason is required for status %', p_to; end if;
  perform set_config('app.status_via_fn', 'on', true);
  update shipments set status_code = p_to, current_branch_id = coalesce(p_branch, current_branch_id) where id = p_shipment;
  insert into shipment_status_events (shipment_id, from_code, to_code, changed_by, branch_id, reason, note, attachment_path)
  values (p_shipment, v_from, p_to, auth.uid(), p_branch, p_reason, p_note, p_attachment);
  if p_to in ('READY_FOR_DISPATCH','RETURN_TO_HUB','RETURN_TO_MERCHANT','CANCELLED','ON_HOLD','LOST','DAMAGED') then
    update shipment_assignments set is_current = false, unassigned_at = now() where shipment_id = p_shipment and is_current;
  end if;
end $$;
revoke execute on function _change_status(uuid,text,text,text,uuid,text) from public, anon, authenticated;

create or replace function change_shipment_status(
  p_shipment uuid, p_to text, p_reason text default null,
  p_note text default null, p_branch uuid default null, p_attachment text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not has_permission('shipments.status') then raise exception 'permission shipments.status required'; end if;
  if not exists (select 1 from shipments where id = p_shipment and company_id = current_company_id()) then
    raise exception 'shipment not found';
  end if;
  perform _change_status(p_shipment, p_to, p_reason, p_note, p_branch, p_attachment);
end $$;

-- ---------- helpers ----------
create or replace function _my_driver_for(p_shipment uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select d.id from drivers d join shipment_assignments a on a.driver_id = d.id
  where a.shipment_id = p_shipment and a.is_current and d.user_id = auth.uid()
    and d.is_active and d.status not in ('suspended','inactive')
$$;
revoke execute on function _my_driver_for(uuid) from public, anon, authenticated;

-- ---------- staff: link a login to a driver ----------
create or replace function link_driver_user(p_driver uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid; d record;
begin
  if not has_permission('drivers.manage') then raise exception 'permission drivers.manage required'; end if;
  select * into d from drivers where id = p_driver and company_id = current_company_id();
  if not found then raise exception 'driver not found'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then raise exception 'no auth user with this email; create it in Supabase Auth first'; end if;
  insert into profiles (id, company_id, full_name, phone) values (v_user, d.company_id, d.full_name, d.phone)
  on conflict (id) do update set company_id = excluded.company_id;
  insert into user_roles (user_id, role_id) select v_user, id from roles where code = 'driver' on conflict do nothing;
  update drivers set user_id = v_user, email = lower(trim(p_email)) where id = p_driver;
end $$;

-- ---------- dispatch ----------
create or replace function assign_shipments(p_driver uuid, p_shipments uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); d record; s record; v_manifest uuid; sid uuid;
        v_override boolean := has_permission('dispatch.override_area');
begin
  if not has_permission('dispatch.assign') then raise exception 'permission dispatch.assign required'; end if;
  select * into d from drivers where id = p_driver and company_id = v_company;
  if not found then raise exception 'driver not found'; end if;
  if not d.is_active or d.status in ('suspended','inactive') then raise exception 'driver % is not active', d.full_name; end if;
  insert into dispatch_manifests (company_id, manifest_no, driver_id, created_by)
  values (v_company, next_doc_no(v_company, 'DM'), p_driver, auth.uid()) returning id into v_manifest;
  foreach sid in array p_shipments loop
    select id, status_code, delivery_area_id, delivery_emirate_id, company_id into s from shipments where id = sid for update;
    if not found or s.company_id <> v_company then raise exception 'shipment not found'; end if;
    if s.status_code <> 'READY_FOR_DISPATCH' then
      raise exception 'shipment is not ready for dispatch (%)', s.status_code;
    end if;
    if not v_override and not exists (
      select 1 from driver_area_assignments a where a.driver_id = p_driver and (
        (a.area_id is not null and a.area_id = s.delivery_area_id) or
        (a.area_id is null and a.emirate_id = s.delivery_emirate_id))) then
      raise exception 'driver % does not cover the area of this shipment', d.full_name;
    end if;
    perform _change_status(sid, 'ASSIGNED_TO_DRIVER', null, 'manifest');
    insert into shipment_assignments (shipment_id, driver_id, manifest_id, assigned_by) values (sid, p_driver, v_manifest, auth.uid());
  end loop;
  return v_manifest;
end $$;

-- automatic dispatch: coverage match, least current load; returns number assigned
create or replace function auto_dispatch(p_shipments uuid[]) returns int
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); sid uuid; s record; v_driver uuid; v_n int := 0; r record;
begin
  if not has_permission('dispatch.assign') then raise exception 'permission dispatch.assign required'; end if;
  create temp table if not exists _plan (shipment_id uuid, driver_id uuid) on commit drop;
  delete from _plan;
  foreach sid in array p_shipments loop
    select id, delivery_area_id, delivery_emirate_id, status_code into s from shipments where id = sid and company_id = v_company;
    if not found or s.status_code <> 'READY_FOR_DISPATCH' then continue; end if;
    select d.id into v_driver from drivers d
     where d.company_id = v_company and d.is_active and d.status in ('available','busy','on_delivery')
       and exists (select 1 from driver_area_assignments a where a.driver_id = d.id and (
            (a.area_id is not null and a.area_id = s.delivery_area_id) or (a.area_id is null and a.emirate_id = s.delivery_emirate_id)))
     order by (select count(*) from shipment_assignments x where x.driver_id = d.id and x.is_current)
              + (select count(*) from _plan p where p.driver_id = d.id), d.driver_no
     limit 1;
    if v_driver is not null then insert into _plan values (sid, v_driver); end if;
  end loop;
  for r in select driver_id, array_agg(shipment_id) ids from _plan group by driver_id loop
    perform assign_shipments(r.driver_id, r.ids);
    v_n := v_n + array_length(r.ids, 1);
  end loop;
  return v_n;
end $$;

create or replace function reassign_shipment(p_shipment uuid, p_driver uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); d record; v_status text; v_manifest uuid;
begin
  if not has_permission('dispatch.assign') then raise exception 'permission dispatch.assign required'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'reason required'; end if;
  select * into d from drivers where id = p_driver and company_id = v_company;
  if not found or not d.is_active or d.status in ('suspended','inactive') then raise exception 'driver not available'; end if;
  select status_code into v_status from shipments where id = p_shipment and company_id = v_company for update;
  if v_status is distinct from 'ASSIGNED_TO_DRIVER' then raise exception 'only shipments assigned but not yet out for delivery can be reassigned (%)', v_status; end if;
  update shipment_assignments set is_current = false, unassigned_at = now() where shipment_id = p_shipment and is_current;
  insert into dispatch_manifests (company_id, manifest_no, driver_id, created_by)
  values (v_company, next_doc_no(v_company, 'DM'), p_driver, auth.uid()) returning id into v_manifest;
  insert into shipment_assignments (shipment_id, driver_id, manifest_id, assigned_by) values (p_shipment, p_driver, v_manifest, auth.uid());
  insert into shipment_status_events (shipment_id, from_code, to_code, changed_by, reason, note)
  values (p_shipment, 'ASSIGNED_TO_DRIVER', 'ASSIGNED_TO_DRIVER', auth.uid(), p_reason, 'reassigned');
end $$;

-- ---------- driver app actions ----------
create or replace function driver_set_status(p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_permission('driver.app') then raise exception 'not a driver'; end if;
  if p_status not in ('available','on_break','offline') then raise exception 'status not allowed'; end if;
  update drivers set status = p_status where user_id = auth.uid() and status not in ('suspended','inactive');
end $$;

create or replace function driver_accept(p_shipment uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if _my_driver_for(p_shipment) is null then raise exception 'not your shipment'; end if;
  update shipment_assignments set accepted_at = coalesce(accepted_at, now()) where shipment_id = p_shipment and is_current;
end $$;

create or replace function driver_out_for_delivery(p_shipment uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if _my_driver_for(p_shipment) is null then raise exception 'not your shipment'; end if;
  perform _change_status(p_shipment, 'OUT_FOR_DELIVERY', null, 'driver');
  update shipment_assignments set accepted_at = coalesce(accepted_at, now()) where shipment_id = p_shipment and is_current;
end $$;

create or replace function driver_deliver(p_shipment uuid, p_receiver text, p_collected numeric, p_method text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_driver uuid := _my_driver_for(p_shipment); s record;
begin
  if v_driver is null then raise exception 'not your shipment'; end if;
  if coalesce(trim(p_receiver),'') = '' then raise exception 'receiver name required'; end if;
  if p_collected is null or p_collected < 0 then raise exception 'collected amount invalid'; end if;
  select cod_amount, payment_method, customer_id into s from shipments where id = p_shipment;
  if p_collected <> s.cod_amount and coalesce(trim(p_note),'') = '' then
    raise exception 'collected amount differs from COD (%): a note is required', s.cod_amount;
  end if;
  perform _change_status(p_shipment, 'DELIVERED', null, p_note);
  insert into proof_of_delivery (shipment_id, driver_id, receiver_name, collected_amount, collected_method, note)
  values (p_shipment, v_driver, trim(p_receiver), p_collected, p_method, p_note);
  update shipments set payment_status = case when p_collected > 0 then 'collected' else payment_status end where id = p_shipment;
  update customers set delivered_count = delivered_count + 1 where id = s.customer_id;
end $$;

create or replace function driver_fail(p_shipment uuid, p_outcome text, p_reason text, p_note text default null, p_reschedule_at timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_driver uuid := _my_driver_for(p_shipment); v_no int; v_cust uuid;
begin
  if v_driver is null then raise exception 'not your shipment'; end if;
  if p_outcome not in ('DELIVERY_FAILED','CUSTOMER_UNAVAILABLE','CUSTOMER_REFUSED','WRONG_ADDRESS','RESCHEDULED') then raise exception 'outcome not allowed'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'reason required'; end if;
  if p_outcome = 'RESCHEDULED' and p_reschedule_at is null then raise exception 'new date required for reschedule'; end if;
  select coalesce(max(attempt_no),0) + 1 into v_no from failed_delivery_attempts where shipment_id = p_shipment;
  perform _change_status(p_shipment, p_outcome, p_reason, p_note);
  insert into failed_delivery_attempts (shipment_id, driver_id, attempt_no, outcome, reason, note, reschedule_at)
  values (p_shipment, v_driver, v_no, p_outcome, trim(p_reason), p_note, p_reschedule_at);
  if p_reschedule_at is not null then update shipments set expected_delivery_at = p_reschedule_at where id = p_shipment; end if;
  if p_outcome = 'CUSTOMER_REFUSED' then
    select customer_id into v_cust from shipments where id = p_shipment;
    update customers set refused_count = refused_count + 1 where id = v_cust;
  end if;
end $$;

create or replace function driver_return_to_hub(p_shipment uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if _my_driver_for(p_shipment) is null then raise exception 'not your shipment'; end if;
  perform _change_status(p_shipment, 'RETURN_TO_HUB', p_reason, 'driver');
end $$;

-- ---------- public tracking (no personal / financial data) ----------
create or replace function public_tracking(p_no text, p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'serial', s.serial_number, 'company_ar', c.name_ar, 'company_en', c.name_en,
    'status_ar', st.name_ar, 'status_en', st.name_en, 'created_at', s.created_at,
    'updated_at', s.updated_at, 'expected_delivery_at', s.expected_delivery_at,
    'events', (select coalesce(jsonb_agg(jsonb_build_object('status_ar', x.name_ar, 'status_en', x.name_en, 'at', e.created_at) order by e.created_at desc), '[]'::jsonb)
               from shipment_status_events e join shipment_statuses x on x.code = e.to_code
               where e.shipment_id = s.id and e.from_code is distinct from e.to_code))
  from shipments s join shipment_statuses st on st.code = s.status_code join companies c on c.id = s.company_id
  where s.tracking_number = p_no and s.tracking_token = p_token and s.deleted_at is null
$$;
grant execute on function public_tracking(text, text) to anon, authenticated;

-- ---------- RLS ----------
alter table drivers                 enable row level security;
alter table vehicles                enable row level security;
alter table driver_area_assignments enable row level security;
alter table doc_counters            enable row level security;
alter table dispatch_manifests      enable row level security;
alter table shipment_assignments    enable row level security;
alter table proof_of_delivery       enable row level security;
alter table failed_delivery_attempts enable row level security;

create policy drivers_read on drivers for select to authenticated
  using (company_id = current_company_id() and (has_permission('drivers.read') or user_id = auth.uid()));
create policy drivers_write on drivers for all to authenticated
  using (company_id = current_company_id() and has_permission('drivers.manage'))
  with check (company_id = current_company_id() and has_permission('drivers.manage'));
create policy vehicles_read on vehicles for select to authenticated using (company_id = current_company_id() and has_permission('drivers.read'));
create policy vehicles_write on vehicles for all to authenticated
  using (company_id = current_company_id() and has_permission('drivers.manage'))
  with check (company_id = current_company_id() and has_permission('drivers.manage'));
create policy dareas_read on driver_area_assignments for select to authenticated
  using (exists (select 1 from drivers d where d.id = driver_id));
create policy dareas_write on driver_area_assignments for all to authenticated
  using (has_permission('drivers.manage')) with check (has_permission('drivers.manage'));

create policy manifests_read on dispatch_manifests for select to authenticated using (
  company_id = current_company_id() and (has_permission('shipments.read_all')
    or exists (select 1 from drivers d where d.id = driver_id and d.user_id = auth.uid())));
create policy assignments_read on shipment_assignments for select to authenticated using (
  has_permission('shipments.read_all') or exists (select 1 from drivers d where d.id = driver_id and d.user_id = auth.uid()));
create policy pod_read on proof_of_delivery for select to authenticated using (exists (select 1 from shipments s where s.id = shipment_id));
create policy fails_read on failed_delivery_attempts for select to authenticated using (exists (select 1 from shipments s where s.id = shipment_id));

-- a driver sees ONLY shipments currently assigned to them
create policy shipments_driver_read on shipments for select to authenticated using (
  has_permission('driver.app') and exists (
    select 1 from shipment_assignments a join drivers d on d.id = a.driver_id
    where a.shipment_id = shipments.id and a.is_current and d.user_id = auth.uid()));

-- ############ 0004_finance_cod.sql ############
-- =====================================================================
-- MAKKAH DELIVERY — Phase 3 — 0004_finance_cod.sql
-- COD ledger, driver cash custody, merchant ledger, settlements,
-- invoices, expenses, payments, period locks and financial reporting.
--
-- Design rules enforced here (not in the UI):
--   * money is numeric(12,2), never float;
--   * financial rows are append-only; corrections use reversing entries;
--   * every posting is idempotent (idempotency_key / natural keys);
--   * COD is a liability to the merchant, never company revenue;
--   * delivery fees are revenue, VAT is a liability;
--   * settlement approval is separated from settlement creation;
--   * closed accounting periods reject new postings.
-- =====================================================================

-- ---------- 0. permissions ----------
insert into permissions (code, description) values
  ('finance.read',            'Read financial data'),
  ('finance.manage',          'Post financial transactions'),
  ('settlements.approve',     'Approve merchant settlements'),
  ('settlements.pay',         'Pay merchant settlements'),
  ('settlements.override_sod','Approve a settlement created by the same user'),
  ('cash.manage',             'Record driver cash handovers'),
  ('cash.close',              'Close driver cash sessions'),
  ('expenses.manage',         'Record and approve expenses'),
  ('invoices.manage',         'Issue invoices'),
  ('rates.manage',            'Manage rate cards')
on conflict (code) do nothing;

with m(role, perm) as (values
  ('ops_manager','finance.read'),('ops_manager','cash.manage'),('ops_manager','cash.close'),
  ('branch_manager','finance.read'),('branch_manager','cash.close'),
  ('accountant','finance.read'),('accountant','finance.manage'),('accountant','settlements.approve'),
  ('accountant','settlements.pay'),('accountant','expenses.manage'),('accountant','invoices.manage'),
  ('accountant','rates.manage'),('accountant','cash.manage'),('accountant','cash.close'),
  ('cashier','finance.read'),('cashier','cash.manage'),('cashier','cash.close'),('cashier','settlements.pay'),
  ('auditor','finance.read'),
  ('dispatcher','finance.read'),
  ('merchant_admin','finance.read'),
  ('driver','finance.read')
)
insert into role_permissions (role_id, permission_id)
select r.id, p.id from m join roles r on r.code = m.role join permissions p on p.code = m.perm
on conflict do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id from roles r cross join permissions p where r.code = 'super_admin'
on conflict do nothing;

-- the owner gets every permission except the single-operator override, so that
-- separation of duties on settlements is real by default
insert into role_permissions (role_id, permission_id)
select r.id, p.id from roles r cross join permissions p
where r.code = 'owner' and p.code <> 'settlements.override_sod'
on conflict do nothing;

-- ---------- 1. defensive columns (no-op if Phase 1 already has them) ----------
alter table companies add column if not exists vat_enabled boolean not null default false;
alter table companies add column if not exists vat_rate    numeric(5,2) not null default 0;
alter table companies add column if not exists trn         text;

alter table merchants add column if not exists delivery_fee      numeric(12,2) not null default 0;
alter table merchants add column if not exists return_fee        numeric(12,2) not null default 0;
alter table merchants add column if not exists extra_attempt_fee numeric(12,2) not null default 0;
alter table merchants add column if not exists cod_fee_percent   numeric(5,2)  not null default 0;

alter table shipments add column if not exists delivery_fee      numeric(12,2) not null default 0;
alter table shipments add column if not exists extra_fee         numeric(12,2) not null default 0;
alter table shipments add column if not exists vat_amount        numeric(12,2) not null default 0;
alter table shipments add column if not exists fee_rate_id       uuid;
alter table shipments add column if not exists fees_calculated_at timestamptz;

alter table drivers add column if not exists commission_per_delivery numeric(12,2) not null default 0;

-- ---------- 2. tables ----------

-- accounting periods: lock a month/period once the books are closed
create table if not exists financial_periods (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  period_start date not null,
  period_end date not null,
  status text not null default 'open' check (status in ('open','locked')),
  locked_by uuid,
  locked_at timestamptz,
  note text,
  unique (company_id, period_start, period_end),
  check (period_end >= period_start)
);

create table if not exists rate_cards (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  merchant_id uuid references merchants(id),
  emirate_id uuid references emirates(id),
  service_type text,
  base_fee numeric(12,2) not null default 0 check (base_fee >= 0),
  per_kg_fee numeric(12,2) not null default 0 check (per_kg_fee >= 0),
  return_fee numeric(12,2) not null default 0 check (return_fee >= 0),
  cod_fee_percent numeric(5,2) not null default 0 check (cod_fee_percent between 0 and 100),
  priority int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid
);
create index if not exists rate_cards_lookup_idx on rate_cards(company_id, merchant_id, emirate_id, service_type) where is_active;

-- COD collections, one row per delivered shipment
create table if not exists cod_transactions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  shipment_id uuid not null references shipments(id),
  merchant_id uuid not null references merchants(id),
  driver_id uuid references drivers(id),
  amount numeric(12,2) not null check (amount > 0),
  handed_amount numeric(12,2) not null default 0 check (handed_amount >= 0),
  collected_method text not null default 'cash' check (collected_method in ('cash','card','online_paid','prepaid','cod')),
  occurred_at timestamptz not null default now(),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (shipment_id),
  check (handed_amount <= amount)
);
create index if not exists cod_tx_driver_idx on cod_transactions(driver_id, occurred_at);
create index if not exists cod_tx_company_idx on cod_transactions(company_id, occurred_at);

-- driver account: 'cash' = company money held by the driver,
--                 'dues' = company money owed to the driver
create table if not exists driver_ledger (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  driver_id uuid not null references drivers(id),
  account text not null check (account in ('cash','dues')),
  entry_type text not null check (entry_type in (
    'cod_collection','cash_handover','commission','advance','expense_reimbursement',
    'deduction','cash_shortage','cash_overage','payout','adjustment','reversal')),
  amount numeric(12,2) not null check (amount > 0),
  direction smallint not null check (direction in (-1,1)),
  shipment_id uuid references shipments(id),
  session_id uuid,
  reference text,
  note text,
  occurred_at timestamptz not null default now(),
  created_by uuid,
  created_at timestamptz not null default now(),
  idempotency_key uuid,
  reverses_id uuid unique references driver_ledger(id),
  unique (company_id, idempotency_key)
);
create index if not exists driver_ledger_driver_idx on driver_ledger(driver_id, occurred_at);
create unique index if not exists driver_ledger_shipment_entry_idx
  on driver_ledger(shipment_id, entry_type, reference) where shipment_id is not null;

create table if not exists driver_cash_sessions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  driver_id uuid not null references drivers(id),
  business_date date not null,
  status text not null default 'open' check (status in ('open','closed')),
  opening_balance numeric(12,2) not null default 0,
  collected_cod numeric(12,2) not null default 0,
  handed_over numeric(12,2) not null default 0,
  expenses_paid numeric(12,2) not null default 0,
  expected_cash numeric(12,2),
  counted_cash numeric(12,2),
  difference numeric(12,2),
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by uuid,
  note text,
  unique (company_id, driver_id, business_date)
);

-- merchant account: positive = company owes the merchant
create table if not exists merchant_ledger (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  merchant_id uuid not null references merchants(id),
  shipment_id uuid references shipments(id),
  settlement_id uuid,
  entry_type text not null check (entry_type in (
    'cod_collected','delivery_fee','extra_fee','vat_on_fee','cod_fee','return_fee',
    'extra_attempt_fee','settlement_payment','adjustment','reversal')),
  amount numeric(12,2) not null check (amount > 0),
  direction smallint not null check (direction in (-1,1)),
  reference text,
  note text,
  occurred_at timestamptz not null default now(),
  created_by uuid,
  created_at timestamptz not null default now(),
  idempotency_key uuid,
  reverses_id uuid unique references merchant_ledger(id),
  unique (company_id, idempotency_key)
);
create index if not exists merchant_ledger_merchant_idx on merchant_ledger(merchant_id, occurred_at);
create index if not exists merchant_ledger_open_idx on merchant_ledger(company_id, merchant_id) where settlement_id is null;
create unique index if not exists merchant_ledger_shipment_entry_idx
  on merchant_ledger(shipment_id, entry_type, reference) where shipment_id is not null;

create table if not exists merchant_settlements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  settlement_no text not null unique,
  merchant_id uuid not null references merchants(id),
  period_start date not null,
  period_end date not null,
  shipments_count int not null default 0,
  cod_total numeric(12,2) not null default 0,
  delivery_fees numeric(12,2) not null default 0,
  extra_fees numeric(12,2) not null default 0,
  vat_total numeric(12,2) not null default 0,
  cod_fees numeric(12,2) not null default 0,
  return_fees numeric(12,2) not null default 0,
  adjustments numeric(12,2) not null default 0,
  net_payable numeric(12,2) not null default 0,
  currency char(3) not null default 'AED',
  status text not null default 'draft'
    check (status in ('draft','under_review','approved','paid','cancelled')),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_by uuid,
  approved_at timestamptz,
  paid_at timestamptz,
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancel_reason text,
  idempotency_key uuid,
  unique (company_id, idempotency_key),
  check (period_end >= period_start)
);
create index if not exists settlements_merchant_idx on merchant_settlements(merchant_id, created_at desc);

create table if not exists settlement_lines (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references merchant_settlements(id) on delete cascade,
  ledger_id uuid not null references merchant_ledger(id),
  shipment_id uuid references shipments(id),
  entry_type text not null,
  description text,
  amount numeric(12,2) not null,   -- signed: + payable to merchant, - deduction
  created_at timestamptz not null default now(),
  unique (ledger_id)
);

create table if not exists invoices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  invoice_no text not null unique,
  merchant_id uuid not null references merchants(id),
  settlement_id uuid references merchant_settlements(id),
  invoice_type text not null default 'delivery' check (invoice_type in ('delivery','cod','other')),
  issue_date date not null default (now() at time zone 'Asia/Dubai')::date,
  due_date date,
  subtotal numeric(12,2) not null default 0,
  vat_amount numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  currency char(3) not null default 'AED',
  status text not null default 'draft' check (status in ('draft','issued','paid','void')),
  notes text,
  created_by uuid,
  created_at timestamptz not null default now(),
  idempotency_key uuid,
  unique (company_id, idempotency_key)
);

create table if not exists invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references invoices(id) on delete cascade,
  description text not null,
  qty numeric(12,2) not null default 1,
  unit_price numeric(12,2) not null default 0,
  vat_rate numeric(5,2) not null default 0,
  line_total numeric(12,2) not null default 0
);

create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  expense_no text,
  branch_id uuid references branches(id),
  driver_id uuid references drivers(id),
  category text not null,
  description text,
  amount numeric(12,2) not null check (amount > 0),
  vat_amount numeric(12,2) not null default 0,
  expense_date date not null default (now() at time zone 'Asia/Dubai')::date,
  paid_from text not null default 'bank' check (paid_from in ('bank','cash','driver_cash')),
  status text not null default 'draft' check (status in ('draft','approved','paid','rejected')),
  approved_by uuid,
  approved_at timestamptz,
  paid_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  idempotency_key uuid,
  unique (company_id, idempotency_key)
);

create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  payment_no text,
  party_type text not null check (party_type in ('merchant','driver','supplier')),
  party_id uuid not null,
  direction text not null check (direction in ('out','in')),
  amount numeric(12,2) not null check (amount > 0),
  method text not null default 'bank' check (method in ('cash','bank','card','cheque','online')),
  reference text,
  payment_date date not null default (now() at time zone 'Asia/Dubai')::date,
  settlement_id uuid references merchant_settlements(id),
  expense_id uuid references expenses(id),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  idempotency_key uuid,
  unique (company_id, idempotency_key)
);

-- ---------- 3. helpers ----------

create or replace function round_money(p numeric) returns numeric
language sql immutable as $$ select round(coalesce(p,0), 2) $$;

create or replace function my_driver_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from drivers where user_id = auth.uid() and is_active limit 1
$$;

create or replace function current_merchant_id() returns uuid
language sql stable security definer set search_path = public as $$
  select merchant_id from profiles where id = auth.uid()
$$;

create or replace function assert_period_open(p_company uuid, p_date timestamptz) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if exists (
    select 1 from financial_periods
    where company_id = p_company and status = 'locked'
      and (p_date at time zone 'Asia/Dubai')::date between period_start and period_end
  ) then
    raise exception 'accounting period is locked for %', (p_date at time zone 'Asia/Dubai')::date;
  end if;
end $$;

-- most specific active rate card wins; falls back to the merchant contract
create or replace function resolve_delivery_fee(
  p_company uuid, p_merchant uuid, p_emirate uuid, p_service text, p_weight numeric
) returns table (fee numeric, rate_id uuid, return_fee numeric, cod_fee_percent numeric, source text)
language plpgsql stable security definer set search_path = public as $$
declare r record; m record; v_fee numeric; v_weight numeric := ceil(coalesce(p_weight, 0));
begin
  select * into r from rate_cards
  where company_id = p_company and is_active
    and (merchant_id is null or merchant_id = p_merchant)
    and (emirate_id is null or emirate_id = p_emirate)
    and (service_type is null or service_type = p_service)
  order by (merchant_id is not null) desc, (service_type is not null) desc, (emirate_id is not null) desc, priority desc, created_at desc
  limit 1;

  if found then
    v_fee := round_money(r.base_fee + r.per_kg_fee * v_weight);
    return query select v_fee, r.id, r.return_fee, r.cod_fee_percent, 'rate_card'::text;
    return;
  end if;

  select * into m from merchants where id = p_merchant and company_id = p_company;
  if not found then raise exception 'merchant not found'; end if;
  return query select round_money(m.delivery_fee), null::uuid, round_money(m.return_fee),
                      coalesce(m.cod_fee_percent, 0), 'merchant_contract'::text;
end $$;

create or replace function _ensure_shipment_fees(p_shipment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s record; c record; v record; v_fee numeric; v_vat numeric; v_rate uuid;
begin
  select * into s from shipments where id = p_shipment;
  if not found then raise exception 'shipment not found'; end if;
  if s.fees_calculated_at is not null then return; end if;

  if s.delivery_fee > 0 then
    v_fee := s.delivery_fee;
    v_rate := s.fee_rate_id;
  else
    select * into v from resolve_delivery_fee(s.company_id, s.merchant_id, s.delivery_emirate_id, s.service_type, s.weight_kg);
    v_fee := v.fee;
    v_rate := v.rate_id;
  end if;

  select * into c from companies where id = s.company_id;
  v_vat := case when c.vat_enabled then round_money((v_fee + coalesce(s.extra_fee,0)) * c.vat_rate / 100) else 0 end;

  update shipments
     set delivery_fee = v_fee,
         vat_amount = v_vat,
         fee_rate_id = coalesce(v_rate, fee_rate_id),
         fees_calculated_at = now()
   where id = p_shipment and fees_calculated_at is null;
end $$;

create or replace function _open_session(p_company uuid, p_driver uuid, p_at timestamptz) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_date date := (p_at at time zone 'Asia/Dubai')::date; v_id uuid; v_opening numeric;
begin
  select id into v_id from driver_cash_sessions
   where company_id = p_company and driver_id = p_driver and business_date = v_date;
  if v_id is not null then return v_id; end if;

  select coalesce(sum(direction * amount), 0) into v_opening
  from driver_ledger
  where driver_id = p_driver and account = 'cash'
    and occurred_at < (v_date::timestamp at time zone 'Asia/Dubai');

  insert into driver_cash_sessions(company_id, driver_id, business_date, opening_balance)
  values (p_company, p_driver, v_date, round_money(v_opening))
  on conflict (company_id, driver_id, business_date) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from driver_cash_sessions
     where company_id = p_company and driver_id = p_driver and business_date = v_date;
  end if;
  return v_id;
end $$;

create or replace function _post_driver_entry(
  p_company uuid, p_driver uuid, p_account text, p_type text, p_amount numeric, p_direction int,
  p_shipment uuid default null, p_session uuid default null, p_reference text default null,
  p_note text default null, p_at timestamptz default now(), p_idem uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_amount is null or p_amount <= 0 then return null; end if;
  perform assert_period_open(p_company, p_at);
  insert into driver_ledger(company_id, driver_id, account, entry_type, amount, direction, shipment_id,
                            session_id, reference, note, occurred_at, created_by, idempotency_key)
  values (p_company, p_driver, p_account, p_type, round_money(p_amount), p_direction, p_shipment,
          p_session, p_reference, p_note, p_at, auth.uid(), p_idem)
  on conflict do nothing
  returning id into v_id;
  return v_id;
end $$;

create or replace function _post_merchant_entry(
  p_company uuid, p_merchant uuid, p_type text, p_amount numeric, p_direction int,
  p_shipment uuid default null, p_reference text default null, p_note text default null,
  p_at timestamptz default now(), p_idem uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_amount is null or p_amount <= 0 then return null; end if;
  perform assert_period_open(p_company, p_at);
  insert into merchant_ledger(company_id, merchant_id, shipment_id, entry_type, amount, direction,
                              reference, note, occurred_at, created_by, idempotency_key)
  values (p_company, p_merchant, p_shipment, p_type, round_money(p_amount), p_direction,
          p_reference, p_note, p_at, auth.uid(), p_idem)
  on conflict do nothing
  returning id into v_id;
  return v_id;
end $$;

-- ---------- 4. automatic postings ----------

-- delivery: COD becomes a merchant liability, fees become revenue, commission accrues
create or replace function _post_delivery_finance(p_pod uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p record; s record; m record; v_session uuid; v_cod_fee numeric; v_commission numeric;
begin
  select * into p from proof_of_delivery where id = p_pod;
  if not found then return; end if;
  perform _ensure_shipment_fees(p.shipment_id);
  select * into s from shipments where id = p.shipment_id;
  select * into m from merchants where id = s.merchant_id;

  v_session := _open_session(s.company_id, p.driver_id, p.delivered_at);

  -- COD collected by the driver (actual amount handed over by the customer)
  if p.collected_amount > 0 then
    insert into cod_transactions(company_id, shipment_id, merchant_id, driver_id, amount, collected_method, occurred_at, note, created_by)
    values (s.company_id, s.id, s.merchant_id, p.driver_id, round_money(p.collected_amount), p.collected_method, p.delivered_at, p.note, auth.uid())
    on conflict (shipment_id) do nothing;

    if found then
      perform _post_driver_entry(s.company_id, p.driver_id, 'cash', 'cod_collection', p.collected_amount, 1,
                                 s.id, v_session, 'pod', 'COD collected', p.delivered_at);
      perform _post_merchant_entry(s.company_id, s.merchant_id, 'cod_collected', p.collected_amount, 1,
                                   s.id, 'pod', 'COD collected', p.delivered_at);
    end if;
  end if;

  -- revenue and deductions
  perform _post_merchant_entry(s.company_id, s.merchant_id, 'delivery_fee', s.delivery_fee, -1, s.id, 'delivery', null, p.delivered_at);
  perform _post_merchant_entry(s.company_id, s.merchant_id, 'extra_fee', s.extra_fee, -1, s.id, 'delivery', null, p.delivered_at);
  perform _post_merchant_entry(s.company_id, s.merchant_id, 'vat_on_fee', s.vat_amount, -1, s.id, 'delivery', null, p.delivered_at);

  v_cod_fee := round_money(p.collected_amount * coalesce(m.cod_fee_percent, 0) / 100);
  perform _post_merchant_entry(s.company_id, s.merchant_id, 'cod_fee', v_cod_fee, -1, s.id, 'delivery', 'COD handling fee', p.delivered_at);

  v_commission := round_money(coalesce((select commission_per_delivery from drivers where id = p.driver_id), 0));
  perform _post_driver_entry(s.company_id, p.driver_id, 'dues', 'commission', v_commission, 1,
                             s.id, v_session, 'delivery', 'Delivery commission', p.delivered_at);
end $$;

create or replace function trg_pod_finance() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform _post_delivery_finance(new.id);
  return new;
end $$;

drop trigger if exists trg_pod_finance on proof_of_delivery;
create trigger trg_pod_finance after insert on proof_of_delivery
for each row execute function trg_pod_finance();

-- return to merchant: charge the contractual return fee once
create or replace function trg_return_fee() returns trigger
language plpgsql security definer set search_path = public as $$
declare s record; v_fee numeric; v_rate uuid;
begin
  if new.to_code <> 'RETURN_TO_MERCHANT' then return new; end if;
  select * into s from shipments where id = new.shipment_id;
  if not found then return new; end if;
  select coalesce((select return_fee from rate_cards where id = s.fee_rate_id), m.return_fee, 0)
    into v_fee from merchants m where m.id = s.merchant_id;
  perform _post_merchant_entry(s.company_id, s.merchant_id, 'return_fee', coalesce(v_fee,0), -1,
                               s.id, 'return', 'Return to merchant', new.created_at);
  return new;
end $$;

drop trigger if exists trg_return_fee on shipment_status_events;
create trigger trg_return_fee after insert on shipment_status_events
for each row execute function trg_return_fee();

-- every failed attempt after the first is chargeable
create or replace function trg_attempt_fee() returns trigger
language plpgsql security definer set search_path = public as $$
declare s record; v_fee numeric;
begin
  if new.attempt_no <= 1 then return new; end if;
  select * into s from shipments where id = new.shipment_id;
  select extra_attempt_fee into v_fee from merchants where id = s.merchant_id;
  perform _post_merchant_entry(s.company_id, s.merchant_id, 'extra_attempt_fee', coalesce(v_fee,0), -1,
                               s.id, 'attempt:' || new.attempt_no, 'Extra delivery attempt', new.created_at);
  return new;
end $$;

drop trigger if exists trg_attempt_fee on failed_delivery_attempts;
create trigger trg_attempt_fee after insert on failed_delivery_attempts
for each row execute function trg_attempt_fee();

-- fee snapshot at creation so the merchant sees the price before dispatch
create or replace function trg_shipment_fees() returns trigger
language plpgsql security definer set search_path = public as $$
declare c record; v record; v_fee numeric; v_vat numeric;
begin
  if new.fees_calculated_at is not null then return new; end if;
  if new.delivery_fee > 0 then
    v_fee := new.delivery_fee;
  else
    select * into v from resolve_delivery_fee(new.company_id, new.merchant_id, new.delivery_emirate_id, new.service_type, new.weight_kg);
    v_fee := v.fee;
    new.fee_rate_id := v.rate_id;
  end if;
  select * into c from companies where id = new.company_id;
  v_vat := case when c.vat_enabled then round_money((v_fee + coalesce(new.extra_fee,0)) * c.vat_rate / 100) else 0 end;
  new.delivery_fee := v_fee;
  new.vat_amount := v_vat;
  new.fees_calculated_at := now();
  return new;
end $$;

drop trigger if exists trg_shipment_fees on shipments;
create trigger trg_shipment_fees before insert on shipments
for each row execute function trg_shipment_fees();

-- ---------- 5. cash custody ----------

create or replace function record_cash_handover(
  p_driver uuid, p_amount numeric, p_reference text default null, p_note text default null,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_session uuid; v_id uuid; v_balance numeric; v_left numeric; r record;
begin
  if not (has_permission('cash.manage') or has_permission('finance.manage')) then
    raise exception 'permission cash.manage required';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if not exists (select 1 from drivers where id = p_driver and company_id = v_company) then
    raise exception 'driver not found';
  end if;

  -- replay of the same handover must return the original row, never post twice
  if p_idempotency_key is not null then
    select id into v_id from driver_ledger
     where company_id = v_company and idempotency_key = p_idempotency_key and entry_type = 'cash_handover';
    if v_id is not null then return v_id; end if;
  end if;

  v_session := _open_session(v_company, p_driver, now());

  select coalesce(sum(direction * amount), 0) into v_balance
  from driver_ledger where driver_id = p_driver and account = 'cash';
  if round_money(p_amount) > round_money(v_balance) then
    raise exception 'handover (%) exceeds the driver cash balance (%)', round_money(p_amount), round_money(v_balance);
  end if;

  v_id := _post_driver_entry(v_company, p_driver, 'cash', 'cash_handover', p_amount, -1,
                             null, v_session, p_reference, p_note, now(), p_idempotency_key);
  if v_id is null then return null; end if;  -- idempotent replay

  -- allocate the handover to COD rows, oldest first
  v_left := round_money(p_amount);
  for r in select id, amount, handed_amount from cod_transactions
            where driver_id = p_driver and handed_amount < amount
            order by occurred_at for update
  loop
    exit when v_left <= 0;
    declare v_take numeric := least(v_left, r.amount - r.handed_amount);
    begin
      update cod_transactions set handed_amount = handed_amount + v_take where id = r.id;
      v_left := round_money(v_left - v_take);
    end;
  end loop;

  update driver_cash_sessions
     set handed_over = round_money(handed_over + p_amount)
   where id = v_session;
  return v_id;
end $$;

create or replace function close_driver_cash_session(
  p_session uuid, p_counted numeric, p_note text default null
) returns numeric
language plpgsql security definer set search_path = public as $$
declare s record; v_expected numeric; v_diff numeric; v_collected numeric; v_expenses numeric;
begin
  if not (has_permission('cash.close') or has_permission('finance.manage')) then
    raise exception 'permission cash.close required';
  end if;
  select * into s from driver_cash_sessions where id = p_session and company_id = current_company_id() for update;
  if not found then raise exception 'session not found'; end if;
  if s.status = 'closed' then raise exception 'session already closed'; end if;
  if p_counted is null or p_counted < 0 then raise exception 'counted amount invalid'; end if;

  select coalesce(sum(direction * amount), 0) into v_expected
  from driver_ledger where session_id = p_session and account = 'cash';
  v_expected := round_money(s.opening_balance + v_expected);

  select coalesce(sum(amount), 0) into v_collected from driver_ledger
   where session_id = p_session and account = 'cash' and entry_type = 'cod_collection';
  select coalesce(sum(amount), 0) into v_expenses from driver_ledger
   where session_id = p_session and account = 'cash' and entry_type = 'expense_reimbursement';

  v_diff := round_money(p_counted - v_expected);
  if v_diff <> 0 and coalesce(trim(p_note), '') = '' then
    raise exception 'a note is required when the counted cash differs by %', v_diff;
  end if;

  if v_diff < 0 then
    perform _post_driver_entry(s.company_id, s.driver_id, 'cash', 'cash_shortage', -v_diff, 1,
                               null, p_session, 'close', p_note, now());
  elsif v_diff > 0 then
    perform _post_driver_entry(s.company_id, s.driver_id, 'cash', 'cash_overage', v_diff, -1,
                               null, p_session, 'close', p_note, now());
  end if;

  update driver_cash_sessions
     set status = 'closed', expected_cash = v_expected, counted_cash = round_money(p_counted),
         difference = v_diff, collected_cod = round_money(v_collected), expenses_paid = round_money(v_expenses),
         closed_at = now(), closed_by = auth.uid(), note = coalesce(p_note, note)
   where id = p_session;
  return v_diff;
end $$;

create or replace function pay_driver_dues(
  p_driver uuid, p_amount numeric, p_method text default 'cash', p_reference text default null,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_balance numeric; v_pay uuid;
begin
  if not has_permission('finance.manage') then raise exception 'permission finance.manage required'; end if;
  if p_idempotency_key is not null then
    select id into v_pay from payments where company_id = v_company and idempotency_key = p_idempotency_key;
    if v_pay is not null then return v_pay; end if;
  end if;
  select coalesce(sum(direction * amount), 0) into v_balance
  from driver_ledger where driver_id = p_driver and account = 'dues';
  if p_amount > v_balance then raise exception 'payout exceeds driver dues (%)', round_money(v_balance); end if;

  insert into payments(company_id, party_type, party_id, direction, amount, method, reference, created_by, idempotency_key)
  values (v_company, 'driver', p_driver, 'out', round_money(p_amount), p_method, p_reference, auth.uid(), p_idempotency_key)
  on conflict do nothing returning id into v_pay;
  if v_pay is null then return null; end if;

  perform _post_driver_entry(v_company, p_driver, 'dues', 'payout', p_amount, -1, null, null, p_reference, null, now(), p_idempotency_key);
  return v_pay;
end $$;

-- ---------- 6. merchant settlement ----------

create or replace function create_merchant_settlement(
  p_merchant uuid, p_from date, p_to date, p_note text default null, p_idempotency_key uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_id uuid; v_count int := 0; v_cod numeric := 0; v_fee numeric := 0;
        v_extra numeric := 0; v_vat numeric := 0; v_codfee numeric := 0; v_return numeric := 0; v_net numeric := 0; r record;
begin
  if not (has_permission('finance.manage') or has_permission('settlements.approve')) then
    raise exception 'permission finance.manage required';
  end if;
  if p_to < p_from then raise exception 'invalid period'; end if;
  if not exists (select 1 from merchants where id = p_merchant and company_id = v_company) then
    raise exception 'merchant not found';
  end if;

  if p_idempotency_key is not null then
    select id into v_id from merchant_settlements where company_id = v_company and idempotency_key = p_idempotency_key;
    if v_id is not null then return v_id; end if;
  end if;

  if not exists (
    select 1 from merchant_ledger
    where company_id = v_company and merchant_id = p_merchant and settlement_id is null
      and (occurred_at at time zone 'Asia/Dubai')::date between p_from and p_to
  ) then
    raise exception 'no open ledger entries for this merchant in the selected period';
  end if;

  insert into merchant_settlements(company_id, settlement_no, merchant_id, period_start, period_end, note, created_by, idempotency_key)
  values (v_company, next_doc_no(v_company, 'STL'), p_merchant, p_from, p_to, p_note, auth.uid(), p_idempotency_key)
  returning id into v_id;

  for r in select * from merchant_ledger
            where company_id = v_company and merchant_id = p_merchant and settlement_id is null
              and (occurred_at at time zone 'Asia/Dubai')::date between p_from and p_to
            order by occurred_at, id
            for update
  loop
    insert into settlement_lines(settlement_id, ledger_id, shipment_id, entry_type, description, amount)
    values (v_id, r.id, r.shipment_id, r.entry_type,
            initcap(replace(r.entry_type, '_', ' ')), round_money(r.direction * r.amount));

    update merchant_ledger set settlement_id = v_id where id = r.id;
    v_net := v_net + r.direction * r.amount;
    if r.entry_type = 'cod_collected' then v_cod := v_cod + r.amount; v_count := v_count + 1;
    elsif r.entry_type = 'delivery_fee' then v_fee := v_fee + r.amount;
    elsif r.entry_type = 'extra_fee' then v_extra := v_extra + r.amount;
    elsif r.entry_type = 'vat_on_fee' then v_vat := v_vat + r.amount;
    elsif r.entry_type = 'cod_fee' then v_codfee := v_codfee + r.amount;
    elsif r.entry_type = 'return_fee' then v_return := v_return + r.amount;
    end if;
  end loop;

  update merchant_settlements
     set shipments_count = v_count, cod_total = round_money(v_cod), delivery_fees = round_money(v_fee),
         extra_fees = round_money(v_extra), vat_total = round_money(v_vat), cod_fees = round_money(v_codfee),
         return_fees = round_money(v_return), net_payable = round_money(v_net)
   where id = v_id;

  return v_id;
end $$;

create or replace function submit_merchant_settlement(p_settlement uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  if not (has_permission('finance.manage') or has_permission('settlements.approve')) then
    raise exception 'permission finance.manage required';
  end if;
  select * into s from merchant_settlements where id = p_settlement and company_id = current_company_id() for update;
  if not found then raise exception 'settlement not found'; end if;
  if s.status <> 'draft' then raise exception 'only draft settlements can be submitted (%)', s.status; end if;
  update merchant_settlements set status = 'under_review', submitted_at = now() where id = p_settlement;
end $$;

create or replace function approve_merchant_settlement(p_settlement uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  if not has_permission('settlements.approve') then raise exception 'permission settlements.approve required'; end if;
  select * into s from merchant_settlements where id = p_settlement and company_id = current_company_id() for update;
  if not found then raise exception 'settlement not found'; end if;
  if s.status not in ('draft','under_review') then raise exception 'settlement cannot be approved from %', s.status; end if;
  -- role check, not a permission check: some deployments let owner/super_admin
  -- pass every has_permission() call, which would silently defeat this control
  if s.created_by = auth.uid() and not exists (
    select 1 from user_roles ur join roles r on r.id = ur.role_id
    where ur.user_id = auth.uid() and r.code = 'super_admin'
  ) then
    raise exception 'separation of duties: the creator cannot approve this settlement';
  end if;
  update merchant_settlements set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = p_settlement;
end $$;

create or replace function pay_merchant_settlement(
  p_settlement uuid, p_method text default 'bank', p_reference text default null, p_idempotency_key uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare s record; v_pay uuid; v_abs numeric;
begin
  if not has_permission('settlements.pay') then raise exception 'permission settlements.pay required'; end if;
  select * into s from merchant_settlements where id = p_settlement and company_id = current_company_id() for update;
  if not found then raise exception 'settlement not found'; end if;
  if s.status <> 'approved' then raise exception 'settlement must be approved before payment (%)', s.status; end if;
  if s.net_payable = 0 then raise exception 'settlement net is zero'; end if;

  v_abs := abs(s.net_payable);
  insert into payments(company_id, party_type, party_id, direction, amount, method, reference,
                       settlement_id, created_by, idempotency_key)
  values (s.company_id, 'merchant', s.merchant_id,
          case when s.net_payable > 0 then 'out' else 'in' end,
          v_abs, p_method, p_reference, s.id, auth.uid(), p_idempotency_key)
  on conflict do nothing returning id into v_pay;
  if v_pay is null then return null; end if;

  perform _post_merchant_entry(s.company_id, s.merchant_id, 'settlement_payment', v_abs,
                               case when s.net_payable > 0 then -1 else 1 end,
                               null, 'settlement', p_reference, now(), p_idempotency_key);

  update merchant_settlements set status = 'paid', paid_at = now() where id = s.id;
  return v_pay;
end $$;

create or replace function cancel_merchant_settlement(p_settlement uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  if not has_permission('finance.manage') then raise exception 'permission finance.manage required'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason required'; end if;
  select * into s from merchant_settlements where id = p_settlement and company_id = current_company_id() for update;
  if not found then raise exception 'settlement not found'; end if;
  if s.status = 'paid' then raise exception 'a paid settlement cannot be cancelled; post a reversing adjustment'; end if;
  update merchant_ledger set settlement_id = null where settlement_id = s.id;
  update merchant_settlements
     set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = p_reason
   where id = s.id;
end $$;

-- ---------- 7. invoices / expenses / payments ----------

create or replace function create_invoice_from_settlement(p_settlement uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare s record; v_id uuid; v_due date;
begin
  if not has_permission('invoices.manage') then raise exception 'permission invoices.manage required'; end if;
  select * into s from merchant_settlements where id = p_settlement and company_id = current_company_id();
  if not found then raise exception 'settlement not found'; end if;
  if s.status = 'cancelled' then raise exception 'cancelled settlement'; end if;
  if exists (select 1 from invoices where settlement_id = s.id) then
    select id into v_id from invoices where settlement_id = s.id;
    return v_id;
  end if;

  v_due := s.period_end + 30;
  insert into invoices(company_id, invoice_no, merchant_id, settlement_id, invoice_type, due_date,
                       subtotal, vat_amount, total, status, notes, created_by)
  values (s.company_id, next_doc_no(s.company_id, 'INV'), s.merchant_id, s.id, 'delivery', v_due,
          round_money(s.delivery_fees + s.extra_fees + s.return_fees + s.cod_fees), s.vat_total,
          round_money(s.delivery_fees + s.extra_fees + s.return_fees + s.cod_fees + s.vat_total), 'issued',
          'Settlement ' || s.settlement_no, auth.uid())
  returning id into v_id;

  insert into invoice_lines(invoice_id, description, qty, unit_price, vat_rate, line_total)
  values (v_id, 'Delivery fees', s.shipments_count, s.delivery_fees, 0, s.delivery_fees);

  if s.extra_fees > 0 then
    insert into invoice_lines(invoice_id, description, qty, unit_price, vat_rate, line_total)
    values (v_id, 'Additional fees', 1, s.extra_fees, 0, s.extra_fees);
  end if;
  if s.return_fees > 0 then
    insert into invoice_lines(invoice_id, description, qty, unit_price, vat_rate, line_total)
    values (v_id, 'Return fees', 1, s.return_fees, 0, s.return_fees);
  end if;
  if s.cod_fees > 0 then
    insert into invoice_lines(invoice_id, description, qty, unit_price, vat_rate, line_total)
    values (v_id, 'COD handling fees', 1, s.cod_fees, 0, s.cod_fees);
  end if;
  if s.vat_total > 0 then
    insert into invoice_lines(invoice_id, description, qty, unit_price, vat_rate, line_total)
    values (v_id, 'VAT', 1, s.vat_total, 0, s.vat_total);
  end if;

  return v_id;
end $$;

create or replace function record_expense(
  p_category text, p_amount numeric, p_description text default null, p_vat numeric default 0,
  p_paid_from text default 'bank', p_driver uuid default null, p_branch uuid default null,
  p_date date default null, p_idempotency_key uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_id uuid; v_date date := coalesce(p_date, (now() at time zone 'Asia/Dubai')::date);
begin
  if not has_permission('expenses.manage') then raise exception 'permission expenses.manage required'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  perform assert_period_open(v_company, v_date::timestamp at time zone 'Asia/Dubai');
  insert into expenses(company_id, expense_no, branch_id, driver_id, category, description, amount,
                       vat_amount, expense_date, paid_from, created_by, idempotency_key)
  values (v_company, next_doc_no(v_company, 'EXP'), p_branch, p_driver, p_category, p_description,
          round_money(p_amount), round_money(p_vat), v_date, p_paid_from, auth.uid(), p_idempotency_key)
  on conflict do nothing returning id into v_id;
  return v_id;
end $$;

create or replace function approve_expense(p_expense uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e record;
begin
  if not has_permission('expenses.manage') then raise exception 'permission expenses.manage required'; end if;
  select * into e from expenses where id = p_expense and company_id = current_company_id() for update;
  if not found then raise exception 'expense not found'; end if;
  if e.status <> 'draft' then raise exception 'expense is already %', e.status; end if;
  update expenses set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = p_expense;
end $$;

create or replace function pay_expense(p_expense uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e record;
begin
  if not has_permission('expenses.manage') then raise exception 'permission expenses.manage required'; end if;
  select * into e from expenses where id = p_expense and company_id = current_company_id() for update;
  if not found then raise exception 'expense not found'; end if;
  if e.status <> 'approved' then raise exception 'expense must be approved first (%)', e.status; end if;
  if e.paid_from = 'driver_cash' then
    if e.driver_id is null then raise exception 'driver is required for driver cash expenses'; end if;
    perform _post_driver_entry(e.company_id, e.driver_id, 'cash', 'expense_reimbursement', e.amount, -1,
                               null, _open_session(e.company_id, e.driver_id, now()), 'expense', e.description, now());
  end if;
  update expenses set status = 'paid', paid_at = now() where id = p_expense;
end $$;

create or replace function record_adjustment(
  p_party_type text, p_party_id uuid, p_amount numeric, p_reason text, p_direction int default 1,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id();
begin
  if not has_permission('finance.manage') then raise exception 'permission finance.manage required'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason required'; end if;
  if p_party_type = 'merchant' then
    return _post_merchant_entry(v_company, p_party_id, 'adjustment', p_amount, p_direction, null, 'manual', p_reason, now(), p_idempotency_key);
  elsif p_party_type = 'driver' then
    return _post_driver_entry(v_company, p_party_id, 'dues', 'adjustment', p_amount, p_direction, null, null, 'manual', p_reason, now(), p_idempotency_key);
  end if;
  raise exception 'invalid party type';
end $$;

-- ---------- 8. statements ----------

create or replace function merchant_statement(p_merchant uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_open numeric; v_close numeric;
begin
  if not (has_permission('finance.read') or has_permission('shipments.read_own')) then
    raise exception 'permission finance.read required';
  end if;
  if not has_permission('finance.read') and p_merchant <> current_merchant_id() then
    raise exception 'not your merchant account';
  end if;

  select coalesce(sum(direction * amount), 0) into v_open from merchant_ledger
   where company_id = v_company and merchant_id = p_merchant
     and (occurred_at at time zone 'Asia/Dubai')::date < p_from;

  select coalesce(sum(direction * amount), 0) into v_close from merchant_ledger
   where company_id = v_company and merchant_id = p_merchant
     and (occurred_at at time zone 'Asia/Dubai')::date <= p_to;

  return jsonb_build_object(
    'merchant_id', p_merchant,
    'from', p_from, 'to', p_to,
    'opening_balance', round_money(v_open),
    'closing_balance', round_money(v_close),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'date', (l.occurred_at at time zone 'Asia/Dubai')::date,
        'type', l.entry_type, 'description', coalesce(l.note, initcap(replace(l.entry_type,'_',' '))),
        'shipment_id', l.shipment_id, 'settlement_id', l.settlement_id,
        'debit', case when l.direction < 0 then l.amount else 0 end,
        'credit', case when l.direction > 0 then l.amount else 0 end
      ) order by l.occurred_at, l.id)
      from merchant_ledger l
      where l.company_id = v_company and l.merchant_id = p_merchant
        and (l.occurred_at at time zone 'Asia/Dubai')::date between p_from and p_to
    ), '[]'::jsonb)
  );
end $$;

create or replace function driver_statement(p_driver uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_cash numeric; v_dues numeric; v_collected numeric; v_handed numeric;
begin
  if not (has_permission('finance.read') or has_permission('drivers.read')) then
    raise exception 'permission finance.read required';
  end if;
  if not has_permission('finance.read') and p_driver <> my_driver_id() then
    raise exception 'not your driver account';
  end if;

  select coalesce(sum(direction * amount), 0) into v_cash from driver_ledger
   where company_id = v_company and driver_id = p_driver and account = 'cash';
  select coalesce(sum(direction * amount), 0) into v_dues from driver_ledger
   where company_id = v_company and driver_id = p_driver and account = 'dues';

  select coalesce(sum(amount), 0) into v_collected from cod_transactions
   where driver_id = p_driver and (occurred_at at time zone 'Asia/Dubai')::date between p_from and p_to;
  select coalesce(sum(amount), 0) into v_handed from driver_ledger
   where driver_id = p_driver and entry_type = 'cash_handover'
     and (occurred_at at time zone 'Asia/Dubai')::date between p_from and p_to;

  return jsonb_build_object(
    'driver_id', p_driver, 'from', p_from, 'to', p_to,
    'cash_in_hand', round_money(v_cash),
    'dues_balance', round_money(v_dues),
    'cod_collected', round_money(v_collected),
    'cash_handed', round_money(v_handed),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'date', (l.occurred_at at time zone 'Asia/Dubai')::date,
        'account', l.account, 'type', l.entry_type, 'note', l.note,
        'debit', case when l.direction < 0 then l.amount else 0 end,
        'credit', case when l.direction > 0 then l.amount else 0 end
      ) order by l.occurred_at, l.id)
      from driver_ledger l
      where l.company_id = v_company and l.driver_id = p_driver
        and (l.occurred_at at time zone 'Asia/Dubai')::date between p_from and p_to
    ), '[]'::jsonb)
  );
end $$;

create or replace function finance_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_today date := (now() at time zone 'Asia/Dubai')::date;
        v_collected numeric; v_custody numeric; v_handed numeric; v_payable numeric; v_revenue numeric;
        v_vat numeric; v_expenses numeric; v_settle_due numeric;
begin
  if not has_permission('finance.read') then raise exception 'permission finance.read required'; end if;

  select coalesce(sum(amount),0) into v_collected from cod_transactions
   where company_id = v_company and (occurred_at at time zone 'Asia/Dubai')::date = v_today;
  select coalesce(sum(direction*amount),0) into v_custody from driver_ledger
   where company_id = v_company and account = 'cash';
  select coalesce(sum(amount),0) into v_handed from driver_ledger
   where company_id = v_company and entry_type = 'cash_handover'
     and (occurred_at at time zone 'Asia/Dubai')::date = v_today;
  select coalesce(sum(bal),0) into v_payable from (
    select sum(direction*amount) bal from merchant_ledger
    where company_id = v_company and settlement_id is null
    group by merchant_id having sum(direction*amount) > 0
  ) x;
  select coalesce(sum(amount),0) into v_revenue from merchant_ledger
   where company_id = v_company and entry_type in ('delivery_fee','extra_fee','return_fee','cod_fee')
     and (occurred_at at time zone 'Asia/Dubai')::date = v_today;
  select coalesce(sum(amount),0) into v_vat from merchant_ledger
   where company_id = v_company and entry_type = 'vat_on_fee'
     and (occurred_at at time zone 'Asia/Dubai')::date = v_today;
  select coalesce(sum(amount),0) into v_expenses from expenses
   where company_id = v_company and expense_date = v_today and status in ('approved','paid');
  select coalesce(sum(net_payable),0) into v_settle_due from merchant_settlements
   where company_id = v_company and status in ('draft','under_review','approved');

  return jsonb_build_object(
    'date', v_today,
    'cod_collected_today', round_money(v_collected),
    'cod_with_drivers', round_money(v_custody),
    'cash_handed_today', round_money(v_handed),
    'merchant_payable_open', round_money(v_payable),
    'revenue_today', round_money(v_revenue),
    'vat_today', round_money(v_vat),
    'expenses_today', round_money(v_expenses),
    'settlements_in_progress', round_money(v_settle_due)
  );
end $$;

create or replace function cod_reconciliation(p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_date date := coalesce(p_date, (now() at time zone 'Asia/Dubai')::date);
begin
  if not has_permission('finance.read') then raise exception 'permission finance.read required'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'driver_id', d.id, 'driver_name', d.full_name,
      'collected', round_money(coalesce(c.collected,0)),
      'handed', round_money(coalesce(h.handed,0)),
      'custody', round_money(coalesce(bal.balance,0))
    ) order by d.full_name)
    from drivers d
    left join (select driver_id, sum(amount) collected from cod_transactions
               where company_id = v_company and (occurred_at at time zone 'Asia/Dubai')::date = v_date
               group by driver_id) c on c.driver_id = d.id
    left join (select driver_id, sum(amount) handed from driver_ledger
               where company_id = v_company and entry_type = 'cash_handover'
                 and (occurred_at at time zone 'Asia/Dubai')::date = v_date
               group by driver_id) h on h.driver_id = d.id
    left join (select driver_id, sum(direction*amount) balance from driver_ledger
               where company_id = v_company and account = 'cash' group by driver_id) bal on bal.driver_id = d.id
    where d.company_id = v_company and d.is_active
  ), '[]'::jsonb);
end $$;

-- ---------- 9. immutability ----------

create or replace function forbid_financial_change() returns trigger
language plpgsql as $$
begin
  if tg_table_name = 'merchant_ledger' then
    if (new.company_id, new.merchant_id, new.shipment_id, new.entry_type, new.amount, new.direction,
        new.occurred_at, new.reverses_id) is distinct from
       (old.company_id, old.merchant_id, old.shipment_id, old.entry_type, old.amount, old.direction,
        old.occurred_at, old.reverses_id) then
      raise exception 'merchant_ledger is append-only; post a reversing entry instead';
    end if;
    return new;
  end if;

  if tg_table_name = 'driver_ledger' then
    if (new.company_id, new.driver_id, new.account, new.entry_type, new.amount, new.direction,
        new.occurred_at, new.reverses_id) is distinct from
       (old.company_id, old.driver_id, old.account, old.entry_type, old.amount, old.direction,
        old.occurred_at, old.reverses_id) then
      raise exception 'driver_ledger is append-only; post a reversing entry instead';
    end if;
    return new;
  end if;

  if tg_table_name = 'cod_transactions' then
    if (new.company_id, new.shipment_id, new.merchant_id, new.driver_id, new.amount, new.occurred_at)
       is distinct from
       (old.company_id, old.shipment_id, old.merchant_id, old.driver_id, old.amount, old.occurred_at) then
      raise exception 'cod_transactions is append-only';
    end if;
    return new;
  end if;

  return new;
end $$;

drop trigger if exists trg_merchant_ledger_ro on merchant_ledger;
create trigger trg_merchant_ledger_ro before update on merchant_ledger
for each row execute function forbid_financial_change();

drop trigger if exists trg_driver_ledger_ro on driver_ledger;
create trigger trg_driver_ledger_ro before update on driver_ledger
for each row execute function forbid_financial_change();

drop trigger if exists trg_cod_tx_ro on cod_transactions;
create trigger trg_cod_tx_ro before update on cod_transactions
for each row execute function forbid_financial_change();

create or replace function forbid_delete() returns trigger
language plpgsql as $$ begin raise exception 'financial records cannot be deleted'; end $$;

drop trigger if exists trg_merchant_ledger_del on merchant_ledger;
create trigger trg_merchant_ledger_del before delete on merchant_ledger
for each row execute function forbid_delete();

drop trigger if exists trg_driver_ledger_del on driver_ledger;
create trigger trg_driver_ledger_del before delete on driver_ledger
for each row execute function forbid_delete();

drop trigger if exists trg_cod_tx_del on cod_transactions;
create trigger trg_cod_tx_del before delete on cod_transactions
for each row execute function forbid_delete();

-- ---------- 10. RLS ----------

alter table financial_periods      enable row level security;
alter table rate_cards             enable row level security;
alter table cod_transactions       enable row level security;
alter table driver_ledger          enable row level security;
alter table driver_cash_sessions   enable row level security;
alter table merchant_ledger        enable row level security;
alter table merchant_settlements   enable row level security;
alter table settlement_lines       enable row level security;
alter table invoices               enable row level security;
alter table invoice_lines          enable row level security;
alter table expenses               enable row level security;
alter table payments               enable row level security;

drop policy if exists fin_periods_read on financial_periods;
create policy fin_periods_read on financial_periods for select to authenticated
  using (company_id = current_company_id() and has_permission('finance.read'));

drop policy if exists rates_read on rate_cards;
create policy rates_read on rate_cards for select to authenticated
  using (company_id = current_company_id() and (has_permission('finance.read') or has_permission('rates.manage')));

drop policy if exists cod_read on cod_transactions;
create policy cod_read on cod_transactions for select to authenticated using (
  company_id = current_company_id() and (
    has_permission('finance.read')
    or driver_id = my_driver_id()
    or (has_permission('shipments.read_own') and merchant_id = current_merchant_id())
  ));

drop policy if exists driver_ledger_read on driver_ledger;
create policy driver_ledger_read on driver_ledger for select to authenticated using (
  company_id = current_company_id() and (has_permission('finance.read') or driver_id = my_driver_id()));

drop policy if exists cash_sessions_read on driver_cash_sessions;
create policy cash_sessions_read on driver_cash_sessions for select to authenticated using (
  company_id = current_company_id() and (has_permission('finance.read') or driver_id = my_driver_id()));

drop policy if exists merchant_ledger_read on merchant_ledger;
create policy merchant_ledger_read on merchant_ledger for select to authenticated using (
  company_id = current_company_id() and (
    has_permission('finance.read')
    or (has_permission('shipments.read_own') and merchant_id = current_merchant_id())
  ));

drop policy if exists settlements_read on merchant_settlements;
create policy settlements_read on merchant_settlements for select to authenticated using (
  company_id = current_company_id() and (
    has_permission('finance.read')
    or (has_permission('shipments.read_own') and merchant_id = current_merchant_id())
  ));

drop policy if exists settlement_lines_read on settlement_lines;
create policy settlement_lines_read on settlement_lines for select to authenticated using (
  exists (select 1 from merchant_settlements s where s.id = settlement_id));

drop policy if exists invoices_read on invoices;
create policy invoices_read on invoices for select to authenticated using (
  company_id = current_company_id() and (
    has_permission('finance.read')
    or (has_permission('shipments.read_own') and merchant_id = current_merchant_id())
  ));

drop policy if exists invoice_lines_read on invoice_lines;
create policy invoice_lines_read on invoice_lines for select to authenticated using (
  exists (select 1 from invoices i where i.id = invoice_id));

drop policy if exists expenses_read on expenses;
create policy expenses_read on expenses for select to authenticated using (
  company_id = current_company_id() and has_permission('finance.read'));

drop policy if exists payments_read on payments;
create policy payments_read on payments for select to authenticated using (
  company_id = current_company_id() and has_permission('finance.read'));

-- ---------- 11. grants ----------
grant select on financial_periods, rate_cards, cod_transactions, driver_ledger, driver_cash_sessions,
  merchant_ledger, merchant_settlements, settlement_lines, invoices, invoice_lines, expenses, payments
  to authenticated;

revoke execute on function _post_delivery_finance(uuid) from public, anon, authenticated;
revoke execute on function _post_driver_entry(uuid,uuid,text,text,numeric,int,uuid,uuid,text,text,timestamptz,uuid) from public, anon, authenticated;
revoke execute on function _post_merchant_entry(uuid,uuid,text,numeric,int,uuid,text,text,timestamptz,uuid) from public, anon, authenticated;
revoke execute on function _open_session(uuid,uuid,timestamptz) from public, anon, authenticated;
revoke execute on function _ensure_shipment_fees(uuid) from public, anon, authenticated;

grant execute on function record_cash_handover(uuid,numeric,text,text,uuid) to authenticated;
grant execute on function close_driver_cash_session(uuid,numeric,text) to authenticated;
grant execute on function pay_driver_dues(uuid,numeric,text,text,uuid) to authenticated;
grant execute on function create_merchant_settlement(uuid,date,date,text,uuid) to authenticated;
grant execute on function submit_merchant_settlement(uuid) to authenticated;
grant execute on function approve_merchant_settlement(uuid) to authenticated;
grant execute on function pay_merchant_settlement(uuid,text,text,uuid) to authenticated;
grant execute on function cancel_merchant_settlement(uuid,text) to authenticated;
grant execute on function create_invoice_from_settlement(uuid) to authenticated;
grant execute on function record_expense(text,numeric,text,numeric,text,uuid,uuid,date,uuid) to authenticated;
grant execute on function approve_expense(uuid) to authenticated;
grant execute on function pay_expense(uuid) to authenticated;
grant execute on function record_adjustment(text,uuid,numeric,text,int,uuid) to authenticated;
grant execute on function merchant_statement(uuid,date,date) to authenticated;
grant execute on function driver_statement(uuid,date,date) to authenticated;
grant execute on function finance_overview() to authenticated;
grant execute on function cod_reconciliation(date) to authenticated;

-- ############ 0005_returns_ops.sql ############
-- =====================================================================
-- MAKKAH DELIVERY — Phase 4 — 0005_returns_ops.sql
-- Returns lifecycle, reassignment across drivers, bulk barcode scanning,
-- and manifest closing.
--
-- Integrates with 0003 (status engine, assignments, manifests) and 0004
-- (return fee posting on RETURN_TO_MERCHANT).
-- =====================================================================

-- ---------- 0. permissions ----------
insert into permissions (code, description) values
  ('returns.read',   'View returns'),
  ('returns.manage', 'Create and receive returns'),
  ('returns.complete','Inspect and return shipments to the merchant'),
  ('scans.bulk',     'Use bulk barcode scanning')
on conflict (code) do nothing;

with m(role, perm) as (values
  ('ops_manager','returns.read'),('ops_manager','returns.manage'),('ops_manager','returns.complete'),('ops_manager','scans.bulk'),
  ('branch_manager','returns.read'),('branch_manager','returns.manage'),('branch_manager','returns.complete'),('branch_manager','scans.bulk'),
  ('dispatcher','returns.read'),('dispatcher','returns.manage'),('dispatcher','scans.bulk'),
  ('warehouse','returns.read'),('warehouse','returns.manage'),('warehouse','returns.complete'),('warehouse','scans.bulk'),
  ('customer_service','returns.read'),('customer_service','returns.manage'),
  ('accountant','returns.read'),
  ('auditor','returns.read'),
  ('driver','returns.read')
)
insert into role_permissions (role_id, permission_id)
select r.id, p.id from m join roles r on r.code = m.role join permissions p on p.code = m.perm
on conflict do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id from roles r cross join permissions p where r.code in ('super_admin','owner')
on conflict do nothing;

-- ---------- 1. status machine additions ----------
-- A rescheduled shipment can still come back to the hub, and a delivered
-- shipment can be returned (customer return). Both are required by the
-- returns flow; existing pairs are left untouched.
insert into shipment_status_transitions (from_code, to_code) values
  ('RESCHEDULED','RETURN_TO_HUB'),
  ('DELIVERED','RETURN_TO_HUB'),
  ('PICKED_UP','RETURN_TO_HUB'),
  ('RECEIVED_AT_HUB','RETURN_TO_HUB'),
  ('SORTING','RETURN_TO_HUB'),
  ('READY_FOR_DISPATCH','RETURN_TO_HUB'),
  ('RETURN_TO_HUB','RETURN_TO_MERCHANT'),
  ('PICKED_UP','RECEIVED_AT_HUB'),
  ('RECEIVED_AT_HUB','SORTING'),
  ('SORTING','READY_FOR_DISPATCH')
on conflict do nothing;

-- ---------- 2. returns ----------
create table if not exists returns (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  return_no text not null,
  shipment_id uuid not null references shipments(id),
  merchant_id uuid not null references merchants(id),
  customer_id uuid references customers(id),
  return_type text not null default 'customer_return'
    check (return_type in ('customer_return','failed_delivery','refused','wrong_address','damaged','exchange')),
  reason_code text not null,
  reason_note text,
  status text not null default 'requested'
    check (status in ('requested','received_at_hub','inspected','returned_to_merchant','cancelled')),
  branch_id uuid references branches(id),
  requested_by uuid,
  requested_at timestamptz not null default now(),
  received_by uuid,
  received_at timestamptz,
  inspected_by uuid,
  inspected_at timestamptz,
  condition text check (condition in ('good','damaged','missing_items')),
  inspection_note text,
  completed_by uuid,
  completed_at timestamptz,
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, return_no)
);
create index if not exists returns_company_status_idx on returns(company_id, status, created_at desc);
create unique index if not exists returns_one_active_per_shipment
  on returns(shipment_id) where status <> 'cancelled';

drop trigger if exists trg_returns_upd on returns;
create trigger trg_returns_upd before update on returns for each row execute function set_updated_at();

-- ---------- 3. scans + manifests ----------
create table if not exists shipment_scans (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references companies(id),
  shipment_id uuid references shipments(id),
  scanned_code text,
  scan_context text,
  scan_type text,
  batch_id uuid,
  branch_id uuid references branches(id),
  driver_id uuid references drivers(id),
  note text,
  device text,
  scanned_by uuid,
  created_at timestamptz not null default now()
);

alter table shipment_scans add column if not exists company_id uuid references companies(id);
alter table shipment_scans add column if not exists scan_type text;
alter table shipment_scans add column if not exists batch_id uuid;
alter table shipment_scans add column if not exists branch_id uuid references branches(id);
alter table shipment_scans add column if not exists driver_id uuid references drivers(id);
alter table shipment_scans add column if not exists note text;
alter table shipment_scans add column if not exists device text;

create index if not exists shipment_scans_batch_idx on shipment_scans(batch_id);
create unique index if not exists shipment_scans_unique_op
  on shipment_scans(shipment_id, scan_type, batch_id) where batch_id is not null;

alter table dispatch_manifests add column if not exists status text not null default 'open';
alter table dispatch_manifests add column if not exists closed_at timestamptz;
alter table dispatch_manifests add column if not exists closed_by uuid;
alter table dispatch_manifests add column if not exists total_shipments int not null default 0;
alter table dispatch_manifests add column if not exists delivered_count int not null default 0;
alter table dispatch_manifests add column if not exists failed_count int not null default 0;

-- ---------- 4. returns RPCs ----------

create or replace function create_return(
  p_shipment uuid, p_reason_code text, p_note text default null,
  p_type text default 'customer_return', p_branch uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); s record; v_id uuid; v_status text;
begin
  if not (has_permission('returns.manage') or has_permission('shipments.status')) then
    raise exception 'permission returns.manage required';
  end if;
  if coalesce(trim(p_reason_code), '') = '' then raise exception 'reason is required'; end if;

  select * into s from shipments where id = p_shipment and company_id = v_company and deleted_at is null for update;
  if not found then raise exception 'shipment not found'; end if;

  if exists (select 1 from returns where shipment_id = p_shipment and status <> 'cancelled') then
    raise exception 'an active return already exists for this shipment';
  end if;

  v_status := s.status_code;
  if v_status not in ('PICKED_UP','RECEIVED_AT_HUB','SORTING','READY_FOR_DISPATCH',
                      'DELIVERED','DELIVERY_FAILED','CUSTOMER_UNAVAILABLE','CUSTOMER_REFUSED',
                      'WRONG_ADDRESS','RESCHEDULED','OUT_FOR_DELIVERY','RETURN_TO_HUB') then
    raise exception 'shipment status % cannot be returned', v_status;
  end if;

  if v_status <> 'RETURN_TO_HUB' then
    perform _change_status(p_shipment, 'RETURN_TO_HUB', p_reason_code, p_note, p_branch);
  end if;

  insert into returns(company_id, return_no, shipment_id, merchant_id, customer_id, return_type,
                      reason_code, reason_note, branch_id, requested_by)
  values (v_company, next_doc_no(v_company, 'RET'), p_shipment, s.merchant_id, s.customer_id, p_type,
          trim(p_reason_code), p_note, p_branch, auth.uid())
  returning id into v_id;

  return v_id;
end $$;

create or replace function receive_return(p_return uuid, p_branch uuid default null, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not has_permission('returns.manage') then raise exception 'permission returns.manage required'; end if;
  select * into r from returns where id = p_return and company_id = current_company_id() for update;
  if not found then raise exception 'return not found'; end if;
  if r.status <> 'requested' then raise exception 'return is already %', r.status; end if;

  update returns
     set status = 'received_at_hub', received_by = auth.uid(), received_at = now(),
         branch_id = coalesce(p_branch, branch_id), reason_note = coalesce(reason_note, p_note)
   where id = p_return;
end $$;

create or replace function inspect_return(p_return uuid, p_condition text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not has_permission('returns.complete') then raise exception 'permission returns.complete required'; end if;
  if p_condition not in ('good','damaged','missing_items') then raise exception 'invalid condition'; end if;
  select * into r from returns where id = p_return and company_id = current_company_id() for update;
  if not found then raise exception 'return not found'; end if;
  if r.status <> 'received_at_hub' then raise exception 'return must be received before inspection (%)', r.status; end if;

  update returns
     set status = 'inspected', inspected_by = auth.uid(), inspected_at = now(),
         condition = p_condition, inspection_note = p_note
   where id = p_return;
end $$;

create or replace function complete_return(p_return uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not has_permission('returns.complete') then raise exception 'permission returns.complete required'; end if;
  select * into r from returns where id = p_return and company_id = current_company_id() for update;
  if not found then raise exception 'return not found'; end if;
  if r.status <> 'inspected' then raise exception 'return must be inspected first (%)', r.status; end if;

  -- moves the shipment to RETURN_TO_MERCHANT; 0004 charges the return fee
  perform _change_status(r.shipment_id, 'RETURN_TO_MERCHANT', 'return completed', r.inspection_note, r.branch_id);

  update returns
     set status = 'returned_to_merchant', completed_by = auth.uid(), completed_at = now()
   where id = p_return;
end $$;

create or replace function cancel_return(p_return uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not has_permission('returns.manage') then raise exception 'permission returns.manage required'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason required'; end if;
  select * into r from returns where id = p_return and company_id = current_company_id() for update;
  if not found then raise exception 'return not found'; end if;
  if r.status not in ('requested','received_at_hub') then
    raise exception 'a return at % cannot be cancelled', r.status;
  end if;

  update returns
     set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = p_reason
   where id = p_return;
end $$;

-- ---------- 5. reassignment ----------

create or replace function reassign_shipment_ext(
  p_shipment uuid, p_driver uuid, p_reason text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); d record; s record; v_manifest uuid; v_status text;
        v_override boolean := has_permission('dispatch.override_area');
begin
  if not has_permission('dispatch.assign') then raise exception 'permission dispatch.assign required'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason required'; end if;

  select * into d from drivers where id = p_driver and company_id = v_company;
  if not found or not d.is_active or d.status in ('suspended','inactive') then
    raise exception 'driver is not available';
  end if;

  select * into s from shipments where id = p_shipment and company_id = v_company and deleted_at is null for update;
  if not found then raise exception 'shipment not found'; end if;
  v_status := s.status_code;
  if v_status not in ('ASSIGNED_TO_DRIVER','OUT_FOR_DELIVERY','RESCHEDULED') then
    raise exception 'shipment status % cannot be reassigned', v_status;
  end if;

  if not v_override and not exists (
    select 1 from driver_area_assignments a
    where a.driver_id = p_driver and (
      (a.area_id is not null and a.area_id = s.delivery_area_id) or
      (a.area_id is null and a.emirate_id = s.delivery_emirate_id))
  ) then
    raise exception 'driver % does not cover the delivery area', d.full_name;
  end if;

  update shipment_assignments set is_current = false, unassigned_at = now()
   where shipment_id = p_shipment and is_current;

  insert into dispatch_manifests(company_id, manifest_no, driver_id, created_by)
  values (v_company, next_doc_no(v_company, 'DM'), p_driver, auth.uid())
  returning id into v_manifest;

  insert into shipment_assignments(shipment_id, driver_id, manifest_id, assigned_by)
  values (p_shipment, p_driver, v_manifest, auth.uid());

  if v_status = 'RESCHEDULED' then
    perform _change_status(p_shipment, 'ASSIGNED_TO_DRIVER', p_reason, 'reassigned');
  else
    insert into shipment_status_events(shipment_id, from_code, to_code, changed_by, reason, note)
    values (p_shipment, v_status, v_status, auth.uid(), p_reason, 'reassigned to ' || d.full_name);
  end if;

  return v_manifest;
end $$;

-- ---------- 6. bulk scanning ----------

create or replace function bulk_scan(
  p_codes text[], p_scan_type text, p_branch uuid default null,
  p_driver uuid default null, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_batch uuid := gen_random_uuid();
        code text; base text; v_shipment uuid; v_serial text; v_status text;
        v_result text; v_reason text; results jsonb := '[]'::jsonb;
        v_ok int := 0; v_dup int := 0; v_missing int := 0; v_bad int := 0;
begin
  if not (has_permission('scans.bulk') or has_permission('scan.use')) then
    raise exception 'permission scans.bulk required';
  end if;
  if p_scan_type not in ('receive_at_hub','sorting','load_to_driver','return_receive','return_to_merchant') then
    raise exception 'invalid scan type %', p_scan_type;
  end if;

  foreach code in array p_codes loop
    base := regexp_replace(upper(trim(code)), '-P[0-9]{2}$', '');
    v_result := 'ok'; v_reason := null; v_shipment := null; v_serial := null; v_status := null;

    if base = '' then continue; end if;

    select sh.id, sh.serial_number, sh.status_code into v_shipment, v_serial, v_status
    from shipments sh
    where sh.company_id = v_company and sh.deleted_at is null
      and (sh.serial_number = base or sh.tracking_number = base
           or exists (select 1 from shipment_parcels p where p.shipment_id = sh.id and p.parcel_serial = upper(trim(code))))
    limit 1;

    if not found then
      v_result := 'not_found'; v_missing := v_missing + 1;
    else
      if exists (select 1 from shipment_scans sc
                 where sc.shipment_id = v_shipment and sc.scan_type = p_scan_type and sc.batch_id = v_batch) then
        v_result := 'duplicate'; v_dup := v_dup + 1;
      elsif p_scan_type = 'receive_at_hub' and v_status not in ('PICKED_UP','RETURN_TO_HUB') then
        v_result := 'wrong_status'; v_reason := v_status; v_bad := v_bad + 1;
      elsif p_scan_type = 'sorting' and v_status <> 'RECEIVED_AT_HUB' then
        v_result := 'wrong_status'; v_reason := v_status; v_bad := v_bad + 1;
      elsif p_scan_type = 'load_to_driver' and v_status <> 'ASSIGNED_TO_DRIVER' then
        v_result := 'wrong_status'; v_reason := v_status; v_bad := v_bad + 1;
      elsif p_scan_type = 'load_to_driver' and p_driver is not null and not exists (
        select 1 from shipment_assignments a where a.shipment_id = v_shipment and a.is_current and a.driver_id = p_driver) then
        v_result := 'wrong_driver'; v_bad := v_bad + 1;
      elsif p_scan_type in ('return_receive','return_to_merchant') and v_status <> 'RETURN_TO_HUB' then
        v_result := 'wrong_status'; v_reason := v_status; v_bad := v_bad + 1;
      end if;

      if v_result = 'ok' then
        begin
          if p_scan_type = 'receive_at_hub' and v_status = 'PICKED_UP' then
            perform _change_status(v_shipment, 'RECEIVED_AT_HUB', null, 'bulk scan', p_branch);
          elsif p_scan_type = 'sorting' then
            perform _change_status(v_shipment, 'SORTING', null, 'bulk scan', p_branch);
          elsif p_scan_type = 'return_to_merchant' then
            perform _change_status(v_shipment, 'RETURN_TO_MERCHANT', 'bulk scan', p_note, p_branch);
          end if;

          insert into shipment_scans(company_id, shipment_id, scanned_code, scan_context, scan_type,
                                     batch_id, branch_id, driver_id, note, scanned_by)
          values (v_company, v_shipment, upper(trim(code)),
                  case p_scan_type when 'receive_at_hub' then 'receive' when 'sorting' then 'sort'
                                   when 'load_to_driver' then 'dispatch' else 'return' end,   -- Phase 1 scan_context vocabulary
                  p_scan_type,
                  v_batch, p_branch, p_driver, p_note, auth.uid());
          v_ok := v_ok + 1;
        exception when others then
          v_result := 'error'; v_reason := sqlerrm; v_bad := v_bad + 1;
        end;
      end if;
    end if;

    results := results || jsonb_build_object(
      'code', upper(trim(code)), 'serial', v_serial, 'shipment_id', v_shipment,
      'result', v_result, 'reason', v_reason, 'status', v_status
    );
  end loop;

  return jsonb_build_object(
    'batch_id', v_batch, 'scan_type', p_scan_type,
    'ok', v_ok, 'duplicates', v_dup, 'not_found', v_missing, 'rejected', v_bad,
    'results', results
  );
end $$;

-- ---------- 7. manifest closing ----------

create or replace function close_manifest(p_manifest uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); m record; v_total int; v_delivered int; v_failed int;
begin
  if not has_permission('dispatch.assign') then raise exception 'permission dispatch.assign required'; end if;
  select * into m from dispatch_manifests where id = p_manifest and company_id = v_company for update;
  if not found then raise exception 'manifest not found'; end if;
  if m.status = 'closed' then raise exception 'manifest already closed'; end if;

  select count(*)::int,
         (count(*) filter (where sh.status_code = 'DELIVERED'))::int,
         (count(*) filter (where sh.status_code in ('DELIVERY_FAILED','CUSTOMER_UNAVAILABLE','CUSTOMER_REFUSED','WRONG_ADDRESS','RETURN_TO_HUB')))::int
    into v_total, v_delivered, v_failed
  from shipment_assignments a join shipments sh on sh.id = a.shipment_id
  where a.manifest_id = p_manifest;

  update dispatch_manifests
     set status = 'closed', closed_at = now(), closed_by = auth.uid(),
         total_shipments = v_total, delivered_count = v_delivered, failed_count = v_failed
   where id = p_manifest;

  -- free the driver when nothing else is assigned
  if not exists (select 1 from shipment_assignments a where a.driver_id = m.driver_id and a.is_current) then
    update drivers set status = 'available'
     where id = m.driver_id and status not in ('suspended','inactive');
  end if;

  return jsonb_build_object('manifest_id', p_manifest, 'total', v_total,
                            'delivered', v_delivered, 'failed', v_failed);
end $$;

-- ---------- 8. RLS ----------
alter table returns enable row level security;

drop policy if exists returns_read on returns;
create policy returns_read on returns for select to authenticated using (
  company_id = current_company_id() and (
    has_permission('returns.read')
    or (has_permission('shipments.read_own') and merchant_id = current_merchant_id())
    or exists (select 1 from drivers d where d.id = (select a.driver_id from shipment_assignments a
                 where a.shipment_id = returns.shipment_id and a.is_current limit 1) and d.user_id = auth.uid())
  ));

drop policy if exists scans_read on shipment_scans;
create policy scans_read on shipment_scans for select to authenticated using (
  company_id = current_company_id() and has_permission('scan.use'));

-- ---------- 9. grants ----------
grant select on returns to authenticated;
grant select on shipment_scans to authenticated;

revoke execute on function create_return(uuid,text,text,text,uuid) from public, anon;
revoke execute on function receive_return(uuid,uuid,text) from public, anon;
revoke execute on function inspect_return(uuid,text,text) from public, anon;
revoke execute on function complete_return(uuid) from public, anon;
revoke execute on function cancel_return(uuid,text) from public, anon;
revoke execute on function reassign_shipment_ext(uuid,uuid,text) from public, anon;
revoke execute on function bulk_scan(text[],text,uuid,uuid,text) from public, anon;
revoke execute on function close_manifest(uuid) from public, anon;

grant execute on function create_return(uuid,text,text,text,uuid) to authenticated;
grant execute on function receive_return(uuid,uuid,text) to authenticated;
grant execute on function inspect_return(uuid,text,text) to authenticated;
grant execute on function complete_return(uuid) to authenticated;
grant execute on function cancel_return(uuid,text) to authenticated;
grant execute on function reassign_shipment_ext(uuid,uuid,text) to authenticated;
grant execute on function bulk_scan(text[],text,uuid,uuid,text) to authenticated;
grant execute on function close_manifest(uuid) to authenticated;

-- ############ 0006_reports_notifications.sql ############
-- The notifications table is created here (idempotently) because the Phase 1 core schema
-- does not define it. Everything below extends it.
create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  user_id uuid,
  shipment_id uuid,
  type text not null,
  title text,
  body text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

-- MAKKAH DELIVERY — Phase 5/6: reports, notification outbox, audit helpers

insert into permissions (code, description) values
  ('notifications.read','Read notifications'),
  ('notifications.manage','Manage notification delivery'),
  ('reports.export','Export reports')
on conflict (code) do nothing;

with m(role, perm) as (values
 ('super_admin','notifications.read'),('super_admin','notifications.manage'),('super_admin','reports.export'),
 ('owner','notifications.read'),('owner','notifications.manage'),('owner','reports.export'),
 ('ops_manager','notifications.read'),('ops_manager','reports.export'),
 ('branch_manager','notifications.read'),('branch_manager','reports.export'),
 ('dispatcher','notifications.read'),('accountant','notifications.read'),('accountant','reports.export'),
 ('cashier','notifications.read'),('auditor','notifications.read'),('auditor','reports.export'),
 ('driver','notifications.read'),('merchant_admin','notifications.read')
)
insert into role_permissions(role_id, permission_id)
select r.id,p.id from m join roles r on r.code=m.role join permissions p on p.code=m.perm
on conflict do nothing;

create table if not exists notification_deliveries (
 id uuid primary key default gen_random_uuid(),
 notification_id uuid not null references notifications(id) on delete cascade,
 channel text not null check (channel in ('in_app','email','sms','whatsapp','push')),
 provider text,
 status text not null default 'queued' check (status in ('queued','sending','sent','failed','cancelled')),
 attempts int not null default 0,
 last_error text,
 sent_at timestamptz,
 created_at timestamptz not null default now(),
 unique(notification_id, channel)
);

alter table notifications add column if not exists priority text not null default 'normal';
alter table notifications add column if not exists action_url text;
alter table notifications add column if not exists metadata jsonb not null default '{}'::jsonb;
create index if not exists notifications_user_idx on notifications(company_id,user_id,read_at,created_at desc);
create index if not exists notification_deliveries_queue_idx on notification_deliveries(status,created_at);

create or replace function enqueue_notification(
 p_company uuid, p_type text, p_title text, p_body text,
 p_shipment uuid default null, p_user uuid default null,
 p_action_url text default null, p_metadata jsonb default '{}'::jsonb,
 p_channels text[] default array['in_app']::text[]
) returns uuid language plpgsql security definer set search_path=public as $$
declare n uuid; c text;
begin
 insert into notifications(company_id,user_id,shipment_id,type,title,body,action_url,metadata)
 values(p_company,p_user,p_shipment,p_type,p_title,p_body,p_action_url,coalesce(p_metadata,'{}'::jsonb)) returning id into n;
 foreach c in array p_channels loop
   insert into notification_deliveries(notification_id,channel) values(n,c)
   on conflict(notification_id,channel) do nothing;
 end loop;
 return n;
end $$;

create or replace function notification_shipment_event() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_company uuid; v_serial text; v_title text; v_body text;
begin
 select company_id,serial_number into v_company,v_serial from shipments where id=new.shipment_id;
 if v_company is null then return new; end if;
 v_title := 'Shipment '||coalesce(v_serial,new.shipment_id::text)||' updated';
 v_body := coalesce(new.from_code,'NEW')||' → '||new.to_code;
 perform enqueue_notification(v_company,'shipment_status',v_title,v_body,new.shipment_id,null,'/shipments/'||new.shipment_id::text,
   jsonb_build_object('from',new.from_code,'to',new.to_code,'reason',new.reason));
 return new;
end $$;

drop trigger if exists trg_notification_shipment_event on shipment_status_events;
create trigger trg_notification_shipment_event after insert on shipment_status_events
for each row execute function notification_shipment_event();

create or replace function mark_notification_read(p_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not (has_permission('notifications.read')) then raise exception 'permission notifications.read required'; end if;
 update notifications set read_at=coalesce(read_at,now()) where id=p_id and company_id=current_company_id()
 and (user_id is null or user_id=auth.uid());
end $$;

create or replace function report_rows(
 p_report text, p_from date default null, p_to date default null,
 p_status text default null, p_emirate uuid default null, p_area uuid default null,
 p_merchant uuid default null, p_driver uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_company uuid:=current_company_id(); out jsonb;
begin
 if not has_permission('reports.read') then raise exception 'permission reports.read required'; end if;
 if p_report not in ('all_shipments','daily_shipments','delivered','failed','returns','driver_performance','merchant_performance','by_emirate','by_area','daily_cod','driver_cash','merchant_statement','settlements','finance','overdue','attempts','branch_movements','barcode_reprints') then raise exception 'invalid report'; end if;
 if p_report in ('all_shipments','daily_shipments','delivered','failed','overdue') then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (
    select s.id,s.serial_number,s.tracking_number,s.status_code,s.recipient_name,s.cod_amount,s.delivery_fee,
           s.created_at,s.updated_at,s.delivery_emirate_id,s.delivery_area_id,s.merchant_id,
           (select a.driver_id from shipment_assignments a where a.shipment_id=s.id and a.is_current limit 1) driver_id
    from shipments s where s.company_id=v_company and s.deleted_at is null
      and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to)
      and (p_status is null or s.status_code=p_status) and (p_emirate is null or s.delivery_emirate_id=p_emirate)
      and (p_area is null or s.delivery_area_id=p_area) and (p_merchant is null or s.merchant_id=p_merchant)
      and (p_report not in ('delivered','failed','overdue') or
           (p_report='delivered' and s.status_code='DELIVERED') or
           (p_report='failed' and s.status_code in ('DELIVERY_FAILED','CUSTOMER_UNAVAILABLE','CUSTOMER_REFUSED','WRONG_ADDRESS')) or
           (p_report='overdue' and s.status_code not in ('DELIVERED','CANCELLED','RETURN_TO_MERCHANT') and s.created_at < now()-interval '2 days'))
      and (p_report<>'daily_shipments' or s.created_at::date=coalesce(p_from,current_date))
    limit 5000
   ) x;
 elsif p_report='returns' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select id,return_no,shipment_id,merchant_id,status,reason_code,condition,created_at,completed_at from returns where company_id=v_company and (p_from is null or created_at::date>=p_from) and (p_to is null or created_at::date<=p_to) limit 5000) x;
 elsif p_report='driver_performance' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.delivered desc),'[]'::jsonb) into out from (select d.id,d.full_name,count(a.id)::int assigned,count(*) filter(where s.status_code='DELIVERED')::int delivered,count(*) filter(where s.status_code in ('DELIVERY_FAILED','CUSTOMER_UNAVAILABLE','CUSTOMER_REFUSED','WRONG_ADDRESS'))::int failed from drivers d left join shipment_assignments a on a.driver_id=d.id left join shipments s on s.id=a.shipment_id and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to) where d.company_id=v_company and (p_driver is null or d.id=p_driver) group by d.id,d.full_name) x;
 elsif p_report='merchant_performance' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.shipments desc),'[]'::jsonb) into out from (select m.id,m.name,count(s.id)::int shipments,count(*) filter(where s.status_code='DELIVERED')::int delivered,count(*) filter(where s.status_code='RETURN_TO_MERCHANT')::int returns from merchants m left join shipments s on s.merchant_id=m.id and s.company_id=v_company and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to) where m.company_id=v_company and (p_merchant is null or m.id=p_merchant) group by m.id,m.name) x;
 elsif p_report='by_emirate' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.shipments desc),'[]'::jsonb) into out from (select e.id,e.name_ar,e.name_en,count(s.id)::int shipments,count(*) filter(where s.status_code='DELIVERED')::int delivered from emirates e left join shipments s on s.delivery_emirate_id=e.id and s.company_id=v_company and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to) group by e.id,e.name_ar,e.name_en) x;
 elsif p_report='by_area' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.shipments desc),'[]'::jsonb) into out from (select a.id,a.name_ar,a.name_en,count(s.id)::int shipments,count(*) filter(where s.status_code='DELIVERED')::int delivered from areas a left join shipments s on s.delivery_area_id=a.id and s.company_id=v_company and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to) group by a.id,a.name_ar,a.name_en) x;
 elsif p_report='daily_cod' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.report_day desc),'[]'::jsonb) into out from (select occurred_at::date report_day,sum(amount)::numeric total,count(*)::int transactions from cod_transactions where company_id=v_company and (p_from is null or occurred_at::date>=p_from) and (p_to is null or occurred_at::date<=p_to) group by occurred_at::date) x;
 elsif p_report='driver_cash' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb) into out from (select l.driver_id,l.entry_type,l.amount,l.direction,l.occurred_at,l.reference from driver_ledger l where l.company_id=v_company and (p_driver is null or l.driver_id=p_driver) and (p_from is null or l.occurred_at::date>=p_from) and (p_to is null or l.occurred_at::date<=p_to) limit 5000) x;
 elsif p_report='merchant_statement' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb) into out from (select l.merchant_id,l.entry_type,l.amount,l.direction,l.occurred_at,l.reference from merchant_ledger l where l.company_id=v_company and (p_merchant is null or l.merchant_id=p_merchant) and (p_from is null or l.occurred_at::date>=p_from) and (p_to is null or l.occurred_at::date<=p_to) limit 5000) x;
 elsif p_report='settlements' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select id,settlement_no,merchant_id,status,period_start,period_end,net_payable,created_at from merchant_settlements where company_id=v_company and (p_from is null or created_at::date>=p_from) and (p_to is null or created_at::date<=p_to)) x;
 elsif p_report='finance' then
   select jsonb_build_object('overview',finance_overview(),'expenses',(select coalesce(jsonb_agg(to_jsonb(e)),'[]'::jsonb) from expenses e where e.company_id=v_company and (p_from is null or e.created_at::date>=p_from) and (p_to is null or e.created_at::date<=p_to))) into out;
 elsif p_report='attempts' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select f.shipment_id,f.attempt_no,f.outcome,f.reason,f.created_at from failed_delivery_attempts f join shipments s on s.id=f.shipment_id where s.company_id=v_company and (p_from is null or f.created_at::date>=p_from) and (p_to is null or f.created_at::date<=p_to) limit 5000) x;
 elsif p_report='branch_movements' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select e.shipment_id,e.from_code,e.to_code,e.branch_id,e.created_at,e.reason from shipment_status_events e join shipments s on s.id=e.shipment_id where s.company_id=v_company and e.branch_id is not null and (p_from is null or e.created_at::date>=p_from) and (p_to is null or e.created_at::date<=p_to) limit 5000) x;
 elsif p_report='barcode_reprints' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select b.shipment_id,b.printed_by,b.format,(select count(*)>0 from barcode_print_logs b2 where b2.shipment_id=b.shipment_id and b2.created_at<b.created_at) as is_reprint,b.created_at from barcode_print_logs b join shipments sh on sh.id=b.shipment_id where sh.company_id=v_company and (p_from is null or b.created_at::date>=p_from) and (p_to is null or b.created_at::date<=p_to) limit 5000) x;
 end if;
 return coalesce(out,'[]'::jsonb);
end $$;

alter table notifications enable row level security;
drop policy if exists notifications_read on notifications;
create policy notifications_read on notifications for select to authenticated using(company_id=current_company_id() and (user_id is null or user_id=auth.uid()) and has_permission('notifications.read'));
drop policy if exists notification_deliveries_read on notification_deliveries;
create policy notification_deliveries_read on notification_deliveries for select to authenticated using(exists(select 1 from notifications n where n.id=notification_id and n.company_id=current_company_id() and has_permission('notifications.manage')));

grant select on notifications,notification_deliveries to authenticated;
revoke execute on function enqueue_notification(uuid,text,text,text,uuid,uuid,text,jsonb,text[]) from public,anon,authenticated;
grant execute on function mark_notification_read(uuid) to authenticated;
grant execute on function report_rows(text,date,date,text,uuid,uuid,uuid,uuid) to authenticated;

-- ############ 0007_security_fixes.sql ############
-- MAKKAH DELIVERY — P0/P1 hardening

-- Return requests are valid from every operational failure state supported by 0005.
insert into shipment_status_transitions(from_code,to_code) values
 ('DELIVERY_FAILED','RETURN_TO_HUB'),('CUSTOMER_UNAVAILABLE','RETURN_TO_HUB'),
 ('CUSTOMER_REFUSED','RETURN_TO_HUB'),('WRONG_ADDRESS','RETURN_TO_HUB'),
 ('OUT_FOR_DELIVERY','RETURN_TO_HUB')
on conflict do nothing;

-- Explicitly seed report permission even when the original 0001/0002 used a
-- smaller permission catalog.
insert into permissions(code,description) values('reports.read','Read operational reports') on conflict(code) do nothing;
with m(role,perm) as (values
 ('super_admin','reports.read'),('owner','reports.read'),('ops_manager','reports.read'),
 ('branch_manager','reports.read'),('dispatcher','reports.read'),('accountant','reports.read'),
 ('cashier','reports.read'),('auditor','reports.read'),('driver','reports.read'),('merchant_admin','reports.read'))
insert into role_permissions(role_id,permission_id)
select r.id,p.id from m join roles r on r.code=m.role join permissions p on p.code=m.perm
on conflict do nothing;

-- Cross-company RLS hardening for operational records.
drop policy if exists dareas_read on driver_area_assignments;
create policy dareas_read on driver_area_assignments for select to authenticated using (
 exists(select 1 from drivers d where d.id=driver_id and d.company_id=current_company_id())
 and (has_permission('drivers.read') or exists(select 1 from drivers d where d.id=driver_id and d.user_id=auth.uid()))
);
drop policy if exists dareas_write on driver_area_assignments;
create policy dareas_write on driver_area_assignments for all to authenticated using (
 exists(select 1 from drivers d where d.id=driver_id and d.company_id=current_company_id()) and has_permission('drivers.manage')
) with check (
 exists(select 1 from drivers d where d.id=driver_id and d.company_id=current_company_id()) and has_permission('drivers.manage')
);
drop policy if exists assignments_read on shipment_assignments;
create policy assignments_read on shipment_assignments for select to authenticated using (
 exists(select 1 from shipments s where s.id=shipment_id and s.company_id=current_company_id())
 and (has_permission('shipments.read_all') or exists(select 1 from drivers d where d.id=driver_id and d.user_id=auth.uid()))
);
drop policy if exists pod_read on proof_of_delivery;
create policy pod_read on proof_of_delivery for select to authenticated using (
 exists(select 1 from shipments s where s.id=shipment_id and s.company_id=current_company_id())
 and (has_permission('shipments.read_all') or exists(select 1 from shipment_assignments a join drivers d on d.id=a.driver_id where a.shipment_id=proof_of_delivery.shipment_id and d.user_id=auth.uid()))
);
drop policy if exists fails_read on failed_delivery_attempts;
create policy fails_read on failed_delivery_attempts for select to authenticated using (
 exists(select 1 from shipments s where s.id=shipment_id and s.company_id=current_company_id())
 and (has_permission('shipments.read_all') or exists(select 1 from shipment_assignments a join drivers d on d.id=a.driver_id where a.shipment_id=failed_delivery_attempts.shipment_id and d.user_id=auth.uid()))
);

-- Correct COD custody: only cash/cod collections create driver cash custody.
create or replace function _post_delivery_finance(p_pod uuid) returns void
language plpgsql security definer set search_path=public as $$
declare p record; s record; m record; v_session uuid; v_cod_fee numeric; v_commission numeric; v_is_cash boolean;
begin
 select * into p from proof_of_delivery where id=p_pod; if not found then return; end if;
 perform _ensure_shipment_fees(p.shipment_id);
 select * into s from shipments where id=p.shipment_id;
 select * into m from merchants where id=s.merchant_id;
 v_is_cash := coalesce(p.collected_method,'cash') in ('cash','cod');
 if v_is_cash then v_session := _open_session(s.company_id,p.driver_id,p.delivered_at); end if;
 if p.collected_amount > 0 then
   insert into cod_transactions(company_id,shipment_id,merchant_id,driver_id,amount,collected_method,occurred_at,note,created_by)
   values(s.company_id,s.id,s.merchant_id,p.driver_id,round_money(p.collected_amount),p.collected_method,p.delivered_at,p.note,auth.uid())
   on conflict(shipment_id) do nothing;
   if found then
     if v_is_cash then perform _post_driver_entry(s.company_id,p.driver_id,'cash','cod_collection',p.collected_amount,1,s.id,v_session,'pod','COD cash collected',p.delivered_at); end if;
     perform _post_merchant_entry(s.company_id,s.merchant_id,'cod_collected',p.collected_amount,1,s.id,'pod','COD collected',p.delivered_at);
   end if;
 end if;
 perform _post_merchant_entry(s.company_id,s.merchant_id,'delivery_fee',s.delivery_fee,-1,s.id,'delivery',null,p.delivered_at);
 perform _post_merchant_entry(s.company_id,s.merchant_id,'extra_fee',s.extra_fee,-1,s.id,'delivery',null,p.delivered_at);
 perform _post_merchant_entry(s.company_id,s.merchant_id,'vat_on_fee',s.vat_amount,-1,s.id,'delivery',null,p.delivered_at);
 v_cod_fee := round_money(p.collected_amount*coalesce(m.cod_fee_percent,0)/100);
 perform _post_merchant_entry(s.company_id,s.merchant_id,'cod_fee',v_cod_fee,-1,s.id,'delivery','COD handling fee',p.delivered_at);
 v_commission := round_money(coalesce((select commission_per_delivery from drivers where id=p.driver_id),0));
 perform _post_driver_entry(s.company_id,p.driver_id,'dues','commission',v_commission,1,s.id,v_session,'delivery','Delivery commission',p.delivered_at);
end $$;

-- ############ 0008_hardening.sql ############
-- =====================================================================
-- MAKKAH DELIVERY - 0008_hardening.sql
-- 1) Strip anonymous/PUBLIC execute on every function in `public`
--    (only public_tracking stays callable without a login).
-- 2) Dispatch load counts only shipments still with the driver.
-- 3) Deny-by-default safety net: RLS is forced ON for every public table.
-- Idempotent: safe to run more than once.
-- =====================================================================

-- ---------- 1) function privileges ----------
do $$
declare f record; auth_had text[] := '{}';
begin
  -- remember what signed-in users can call today (so we never take that away)
  for f in
    select p.oid, p.oid::regprocedure::text as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind in ('f','p')
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')   -- skip extension functions
  loop
    if has_function_privilege('authenticated', f.oid, 'execute') then auth_had := auth_had || f.sig; end if;
    execute format('revoke execute on function %s from public, anon', f.sig);
  end loop;
  for f in select unnest(auth_had) as sig loop
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from public, anon;   -- future functions
grant execute on function public_tracking(text, text) to anon, authenticated;              -- the only public endpoint

-- ---------- 2) dispatch load ----------
create or replace function auto_dispatch(p_shipments uuid[]) returns int
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); sid uuid; s record; v_driver uuid; v_n int := 0; r record;
begin
  if not has_permission('dispatch.assign') then raise exception 'permission dispatch.assign required'; end if;
  create temp table if not exists _plan (shipment_id uuid, driver_id uuid) on commit drop;
  delete from _plan;
  foreach sid in array p_shipments loop
    select id, delivery_area_id, delivery_emirate_id, status_code into s from shipments where id = sid and company_id = v_company;
    if not found or s.status_code <> 'READY_FOR_DISPATCH' then continue; end if;
    select d.id into v_driver from drivers d
     where d.company_id = v_company and d.is_active and d.status in ('available','busy','on_delivery')
       and exists (select 1 from driver_area_assignments a where a.driver_id = d.id and (
            (a.area_id is not null and a.area_id = s.delivery_area_id) or (a.area_id is null and a.emirate_id = s.delivery_emirate_id)))
     order by (select count(*) from shipment_assignments x join shipments sh on sh.id = x.shipment_id
                where x.driver_id = d.id and x.is_current and sh.status_code in ('ASSIGNED_TO_DRIVER','OUT_FOR_DELIVERY'))
              + (select count(*) from _plan p where p.driver_id = d.id), d.driver_no
     limit 1;
    if v_driver is not null then insert into _plan values (sid, v_driver); end if;
  end loop;
  for r in select driver_id, array_agg(shipment_id) ids from _plan group by driver_id loop
    perform assign_shipments(r.driver_id, r.ids);
    v_n := v_n + array_length(r.ids, 1);
  end loop;
  return v_n;
end $$;


-- ---------- 3) RLS safety net ----------
do $$
declare t record;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
  loop
    execute format('alter table public.%I enable row level security', t.relname);
    raise notice 'RLS enabled on % (no policy = nobody but the service role can read it)', t.relname;
  end loop;
end $$;

-- ---------- 4) repair bulk_scan: (a) shipment_parcels column is parcel_serial, (b) shipment_scans.scan_context only accepts the Phase 1 vocabulary ----------
create or replace function bulk_scan(
  p_codes text[], p_scan_type text, p_branch uuid default null,
  p_driver uuid default null, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_batch uuid := gen_random_uuid();
        code text; base text; v_shipment uuid; v_serial text; v_status text;
        v_result text; v_reason text; results jsonb := '[]'::jsonb;
        v_ok int := 0; v_dup int := 0; v_missing int := 0; v_bad int := 0;
begin
  if not (has_permission('scans.bulk') or has_permission('scan.use')) then
    raise exception 'permission scans.bulk required';
  end if;
  if p_scan_type not in ('receive_at_hub','sorting','load_to_driver','return_receive','return_to_merchant') then
    raise exception 'invalid scan type %', p_scan_type;
  end if;

  foreach code in array p_codes loop
    base := regexp_replace(upper(trim(code)), '-P[0-9]{2}$', '');
    v_result := 'ok'; v_reason := null; v_shipment := null; v_serial := null; v_status := null;

    if base = '' then continue; end if;

    select sh.id, sh.serial_number, sh.status_code into v_shipment, v_serial, v_status
    from shipments sh
    where sh.company_id = v_company and sh.deleted_at is null
      and (sh.serial_number = base or sh.tracking_number = base
           or exists (select 1 from shipment_parcels p where p.shipment_id = sh.id and p.parcel_serial = upper(trim(code))))
    limit 1;

    if not found then
      v_result := 'not_found'; v_missing := v_missing + 1;
    else
      if exists (select 1 from shipment_scans sc
                 where sc.shipment_id = v_shipment and sc.scan_type = p_scan_type and sc.batch_id = v_batch) then
        v_result := 'duplicate'; v_dup := v_dup + 1;
      elsif p_scan_type = 'receive_at_hub' and v_status not in ('PICKED_UP','RETURN_TO_HUB') then
        v_result := 'wrong_status'; v_reason := v_status; v_bad := v_bad + 1;
      elsif p_scan_type = 'sorting' and v_status <> 'RECEIVED_AT_HUB' then
        v_result := 'wrong_status'; v_reason := v_status; v_bad := v_bad + 1;
      elsif p_scan_type = 'load_to_driver' and v_status <> 'ASSIGNED_TO_DRIVER' then
        v_result := 'wrong_status'; v_reason := v_status; v_bad := v_bad + 1;
      elsif p_scan_type = 'load_to_driver' and p_driver is not null and not exists (
        select 1 from shipment_assignments a where a.shipment_id = v_shipment and a.is_current and a.driver_id = p_driver) then
        v_result := 'wrong_driver'; v_bad := v_bad + 1;
      elsif p_scan_type in ('return_receive','return_to_merchant') and v_status <> 'RETURN_TO_HUB' then
        v_result := 'wrong_status'; v_reason := v_status; v_bad := v_bad + 1;
      end if;

      if v_result = 'ok' then
        begin
          if p_scan_type = 'receive_at_hub' and v_status = 'PICKED_UP' then
            perform _change_status(v_shipment, 'RECEIVED_AT_HUB', null, 'bulk scan', p_branch);
          elsif p_scan_type = 'sorting' then
            perform _change_status(v_shipment, 'SORTING', null, 'bulk scan', p_branch);
          elsif p_scan_type = 'return_to_merchant' then
            perform _change_status(v_shipment, 'RETURN_TO_MERCHANT', 'bulk scan', p_note, p_branch);
          end if;

          insert into shipment_scans(company_id, shipment_id, scanned_code, scan_context, scan_type,
                                     batch_id, branch_id, driver_id, note, scanned_by)
          values (v_company, v_shipment, upper(trim(code)),
                  case p_scan_type when 'receive_at_hub' then 'receive' when 'sorting' then 'sort'
                                   when 'load_to_driver' then 'dispatch' else 'return' end,   -- Phase 1 scan_context vocabulary
                  p_scan_type,
                  v_batch, p_branch, p_driver, p_note, auth.uid());
          v_ok := v_ok + 1;
        exception when others then
          v_result := 'error'; v_reason := sqlerrm; v_bad := v_bad + 1;
        end;
      end if;
    end if;

    results := results || jsonb_build_object(
      'code', upper(trim(code)), 'serial', v_serial, 'shipment_id', v_shipment,
      'result', v_result, 'reason', v_reason, 'status', v_status
    );
  end loop;

  return jsonb_build_object(
    'batch_id', v_batch, 'scan_type', p_scan_type,
    'ok', v_ok, 'duplicates', v_dup, 'not_found', v_missing, 'rejected', v_bad,
    'results', results
  );
end $$;

-- ---------- 5) repair report_rows: barcode_reprints used barcode_print_logs.company_id, which Phase 1 does not have (company comes from the shipment) ----------
create or replace function report_rows(
 p_report text, p_from date default null, p_to date default null,
 p_status text default null, p_emirate uuid default null, p_area uuid default null,
 p_merchant uuid default null, p_driver uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_company uuid:=current_company_id(); out jsonb;
begin
 if not has_permission('reports.read') then raise exception 'permission reports.read required'; end if;
 if p_report not in ('all_shipments','daily_shipments','delivered','failed','returns','driver_performance','merchant_performance','by_emirate','by_area','daily_cod','driver_cash','merchant_statement','settlements','finance','overdue','attempts','branch_movements','barcode_reprints') then raise exception 'invalid report'; end if;
 if p_report in ('all_shipments','daily_shipments','delivered','failed','overdue') then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (
    select s.id,s.serial_number,s.tracking_number,s.status_code,s.recipient_name,s.cod_amount,s.delivery_fee,
           s.created_at,s.updated_at,s.delivery_emirate_id,s.delivery_area_id,s.merchant_id,
           (select a.driver_id from shipment_assignments a where a.shipment_id=s.id and a.is_current limit 1) driver_id
    from shipments s where s.company_id=v_company and s.deleted_at is null
      and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to)
      and (p_status is null or s.status_code=p_status) and (p_emirate is null or s.delivery_emirate_id=p_emirate)
      and (p_area is null or s.delivery_area_id=p_area) and (p_merchant is null or s.merchant_id=p_merchant)
      and (p_report not in ('delivered','failed','overdue') or
           (p_report='delivered' and s.status_code='DELIVERED') or
           (p_report='failed' and s.status_code in ('DELIVERY_FAILED','CUSTOMER_UNAVAILABLE','CUSTOMER_REFUSED','WRONG_ADDRESS')) or
           (p_report='overdue' and s.status_code not in ('DELIVERED','CANCELLED','RETURN_TO_MERCHANT') and s.created_at < now()-interval '2 days'))
      and (p_report<>'daily_shipments' or s.created_at::date=coalesce(p_from,current_date))
    limit 5000
   ) x;
 elsif p_report='returns' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select id,return_no,shipment_id,merchant_id,status,reason_code,condition,created_at,completed_at from returns where company_id=v_company and (p_from is null or created_at::date>=p_from) and (p_to is null or created_at::date<=p_to) limit 5000) x;
 elsif p_report='driver_performance' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.delivered desc),'[]'::jsonb) into out from (select d.id,d.full_name,count(a.id)::int assigned,count(*) filter(where s.status_code='DELIVERED')::int delivered,count(*) filter(where s.status_code in ('DELIVERY_FAILED','CUSTOMER_UNAVAILABLE','CUSTOMER_REFUSED','WRONG_ADDRESS'))::int failed from drivers d left join shipment_assignments a on a.driver_id=d.id left join shipments s on s.id=a.shipment_id and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to) where d.company_id=v_company and (p_driver is null or d.id=p_driver) group by d.id,d.full_name) x;
 elsif p_report='merchant_performance' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.shipments desc),'[]'::jsonb) into out from (select m.id,m.name,count(s.id)::int shipments,count(*) filter(where s.status_code='DELIVERED')::int delivered,count(*) filter(where s.status_code='RETURN_TO_MERCHANT')::int returns from merchants m left join shipments s on s.merchant_id=m.id and s.company_id=v_company and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to) where m.company_id=v_company and (p_merchant is null or m.id=p_merchant) group by m.id,m.name) x;
 elsif p_report='by_emirate' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.shipments desc),'[]'::jsonb) into out from (select e.id,e.name_ar,e.name_en,count(s.id)::int shipments,count(*) filter(where s.status_code='DELIVERED')::int delivered from emirates e left join shipments s on s.delivery_emirate_id=e.id and s.company_id=v_company and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to) group by e.id,e.name_ar,e.name_en) x;
 elsif p_report='by_area' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.shipments desc),'[]'::jsonb) into out from (select a.id,a.name_ar,a.name_en,count(s.id)::int shipments,count(*) filter(where s.status_code='DELIVERED')::int delivered from areas a left join shipments s on s.delivery_area_id=a.id and s.company_id=v_company and (p_from is null or s.created_at::date>=p_from) and (p_to is null or s.created_at::date<=p_to) group by a.id,a.name_ar,a.name_en) x;
 elsif p_report='daily_cod' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.report_day desc),'[]'::jsonb) into out from (select occurred_at::date report_day,sum(amount)::numeric total,count(*)::int transactions from cod_transactions where company_id=v_company and (p_from is null or occurred_at::date>=p_from) and (p_to is null or occurred_at::date<=p_to) group by occurred_at::date) x;
 elsif p_report='driver_cash' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb) into out from (select l.driver_id,l.entry_type,l.amount,l.direction,l.occurred_at,l.reference from driver_ledger l where l.company_id=v_company and (p_driver is null or l.driver_id=p_driver) and (p_from is null or l.occurred_at::date>=p_from) and (p_to is null or l.occurred_at::date<=p_to) limit 5000) x;
 elsif p_report='merchant_statement' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc),'[]'::jsonb) into out from (select l.merchant_id,l.entry_type,l.amount,l.direction,l.occurred_at,l.reference from merchant_ledger l where l.company_id=v_company and (p_merchant is null or l.merchant_id=p_merchant) and (p_from is null or l.occurred_at::date>=p_from) and (p_to is null or l.occurred_at::date<=p_to) limit 5000) x;
 elsif p_report='settlements' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select id,settlement_no,merchant_id,status,period_start,period_end,net_payable,created_at from merchant_settlements where company_id=v_company and (p_from is null or created_at::date>=p_from) and (p_to is null or created_at::date<=p_to)) x;
 elsif p_report='finance' then
   select jsonb_build_object('overview',finance_overview(),'expenses',(select coalesce(jsonb_agg(to_jsonb(e)),'[]'::jsonb) from expenses e where e.company_id=v_company and (p_from is null or e.created_at::date>=p_from) and (p_to is null or e.created_at::date<=p_to))) into out;
 elsif p_report='attempts' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select f.shipment_id,f.attempt_no,f.outcome,f.reason,f.created_at from failed_delivery_attempts f join shipments s on s.id=f.shipment_id where s.company_id=v_company and (p_from is null or f.created_at::date>=p_from) and (p_to is null or f.created_at::date<=p_to) limit 5000) x;
 elsif p_report='branch_movements' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select e.shipment_id,e.from_code,e.to_code,e.branch_id,e.created_at,e.reason from shipment_status_events e join shipments s on s.id=e.shipment_id where s.company_id=v_company and e.branch_id is not null and (p_from is null or e.created_at::date>=p_from) and (p_to is null or e.created_at::date<=p_to) limit 5000) x;
 elsif p_report='barcode_reprints' then
   select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select b.shipment_id,b.printed_by,b.format,(select count(*)>0 from barcode_print_logs b2 where b2.shipment_id=b.shipment_id and b2.created_at<b.created_at) as is_reprint,b.created_at from barcode_print_logs b join shipments sh on sh.id=b.shipment_id where sh.company_id=v_company and (p_from is null or b.created_at::date>=p_from) and (p_to is null or b.created_at::date<=p_to) limit 5000) x;
 end if;
 return coalesce(out,'[]'::jsonb);
end $$;

-- ---------- 6) fix infinite RLS recursion on shipments ----------
-- shipments_driver_read (0003) -> shipment_assignments policy (0007) -> shipments policy -> ...  => every SELECT failed.
-- A SECURITY DEFINER helper reads the caller's own assignment without re-entering RLS.
create or replace function is_my_assigned_shipment(p_shipment uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from shipment_assignments a join drivers d on d.id = a.driver_id
    where a.shipment_id = p_shipment and a.is_current and d.user_id = auth.uid()
  )
$$;
revoke execute on function is_my_assigned_shipment(uuid) from public, anon;
grant  execute on function is_my_assigned_shipment(uuid) to authenticated;

drop policy if exists shipments_driver_read on shipments;
create policy shipments_driver_read on shipments for select to authenticated
  using (has_permission('driver.app') and is_my_assigned_shipment(id));

-- ############ 0009_users_admin.sql ############
-- =====================================================================
-- MAKKAH DELIVERY - 0009_users_admin.sql
-- User & role administration from the app (no service_role key needed in the app):
--   * profiles / user_roles are no longer writable directly by anyone; all changes go through
--     guarded functions that enforce company scope, owner-only escalation and last-owner protection.
--   * Fixes a cross-company hole: the old users.manage policies had no company filter.
--   * my_permissions() lets the UI show only what the signed-in user may use.
-- Auth accounts themselves are created in Supabase Auth (Dashboard > Authentication > Users);
-- the app then links the account to this company with provision_user().
-- =====================================================================

-- ---------- policies: company-scoped reads, no direct writes ----------
drop policy if exists profiles_admin on profiles;
drop policy if exists profiles_self  on profiles;
create policy profiles_self on profiles for select to authenticated using (id = auth.uid());
create policy profiles_admin_read on profiles for select to authenticated
  using (company_id = current_company_id() and has_permission('users.manage'));

drop policy if exists userroles_admin on user_roles;
drop policy if exists userroles_read  on user_roles;
create policy userroles_read on user_roles for select to authenticated using (
  user_id = auth.uid()
  or (has_permission('users.manage') and exists (select 1 from profiles p where p.id = user_roles.user_id and p.company_id = current_company_id())));

drop trigger if exists trg_audit_profiles on profiles;
create trigger trg_audit_profiles after insert or update or delete on profiles for each row execute function audit_row();

-- ---------- internal helpers (not callable by clients) ----------
create or replace function _assert_user_admin() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not has_permission('users.manage') then raise exception 'permission users.manage required'; end if;
end $$;

create or replace function _caller_is_top() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles pr join user_roles ur on ur.user_id = pr.id join roles r on r.id = ur.role_id
                 where pr.id = auth.uid() and pr.is_active and r.code in ('owner','super_admin'))
$$;

create or replace function _is_top_user(p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_roles ur join roles r on r.id = ur.role_id where ur.user_id = p_user and r.code in ('owner','super_admin'))
$$;

create or replace function _other_active_owner_exists(p_company uuid, p_except uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles pr join user_roles ur on ur.user_id = pr.id join roles r on r.id = ur.role_id
                 where pr.company_id = p_company and pr.is_active and pr.id <> p_except and r.code in ('owner','super_admin'))
$$;

create or replace function _check_roles(p_roles text[], p_merchant uuid, p_company uuid) returns void language plpgsql stable security definer set search_path = public as $$
declare r text; v_merchant_roles text[] := array['merchant_admin','merchant_employee']; v_has_m boolean; v_has_staff boolean;
begin
  if p_roles is null or cardinality(p_roles) = 0 then raise exception 'at least one role is required'; end if;
  foreach r in array p_roles loop
    if not exists (select 1 from roles where code = r) then raise exception 'unknown role %', r; end if;
  end loop;
  if (p_roles && array['owner','super_admin']) and not _caller_is_top() then
    raise exception 'only an owner can grant the owner role';
  end if;
  v_has_m := p_roles && v_merchant_roles;
  v_has_staff := exists (select 1 from unnest(p_roles) x where x <> all (v_merchant_roles));
  if v_has_m and v_has_staff then raise exception 'merchant roles cannot be combined with staff roles'; end if;
  if v_has_m and p_merchant is null then raise exception 'a merchant is required for merchant roles'; end if;
  if not v_has_m and p_merchant is not null then raise exception 'merchant can only be set for merchant roles'; end if;
  if p_merchant is not null and not exists (select 1 from merchants where id = p_merchant and company_id = p_company) then
    raise exception 'merchant not found';
  end if;
end $$;

-- ---------- app-facing functions ----------
create or replace function my_permissions() returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct pm.code), '{}')
  from profiles pr join user_roles ur on ur.user_id = pr.id join role_permissions rp on rp.role_id = ur.role_id join permissions pm on pm.id = rp.permission_id
  where pr.id = auth.uid() and pr.is_active
$$;

create or replace function list_users() returns table (
  id uuid, email text, full_name text, phone text, is_active boolean, merchant_id uuid, merchant_name text,
  roles text[], last_sign_in_at timestamptz, created_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  perform _assert_user_admin();
  return query
    select pr.id, au.email::text, pr.full_name, pr.phone, pr.is_active, pr.merchant_id, m.name,
           coalesce((select array_agg(r.code order by r.code) from user_roles ur join roles r on r.id = ur.role_id where ur.user_id = pr.id), '{}'),
           au.last_sign_in_at, pr.created_at
    from profiles pr left join auth.users au on au.id = pr.id left join merchants m on m.id = pr.merchant_id
    where pr.company_id = current_company_id()
    order by pr.is_active desc, pr.full_name;
end $$;

create or replace function provision_user(p_email text, p_full_name text, p_roles text[], p_merchant uuid default null,
                                          p_branch uuid default null, p_phone text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_user uuid; v_existing uuid;
begin
  perform _assert_user_admin();
  if coalesce(trim(p_full_name), '') = '' then raise exception 'full name is required'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'no auth account with this email; create it first in Supabase Authentication > Users';
  end if;
  select company_id into v_existing from profiles where id = v_user;
  if v_existing is not null then raise exception 'this account is already registered; edit its roles instead'; end if;
  perform _check_roles(p_roles, p_merchant, v_company);
  if p_branch is not null and not exists (select 1 from branches where id = p_branch and company_id = v_company) then raise exception 'branch not found'; end if;
  insert into profiles (id, company_id, full_name, phone, branch_id, merchant_id)
  values (v_user, v_company, trim(p_full_name), nullif(trim(coalesce(p_phone, '')), ''), p_branch, p_merchant);
  insert into user_roles (user_id, role_id) select v_user, id from roles where code = any (p_roles);
  return v_user;
end $$;

create or replace function set_user_roles(p_user uuid, p_roles text[]) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); t record;
begin
  perform _assert_user_admin();
  select * into t from profiles where id = p_user and company_id = v_company;
  if not found then raise exception 'user not found'; end if;
  if p_user = auth.uid() then raise exception 'you cannot change your own roles'; end if;
  if _is_top_user(p_user) and not _caller_is_top() then raise exception 'only an owner can change an owner'; end if;
  perform _check_roles(p_roles, t.merchant_id, v_company);
  if _is_top_user(p_user) and not (p_roles && array['owner','super_admin']) and not _other_active_owner_exists(v_company, p_user) then
    raise exception 'cannot remove the last owner';
  end if;
  delete from user_roles where user_id = p_user;
  insert into user_roles (user_id, role_id) select p_user, id from roles where code = any (p_roles);
end $$;

create or replace function set_user_active(p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id();
begin
  perform _assert_user_admin();
  if not exists (select 1 from profiles where id = p_user and company_id = v_company) then raise exception 'user not found'; end if;
  if p_user = auth.uid() then raise exception 'you cannot deactivate yourself'; end if;
  if _is_top_user(p_user) and not _caller_is_top() then raise exception 'only an owner can change an owner'; end if;
  if not p_active and _is_top_user(p_user) and not _other_active_owner_exists(v_company, p_user) then raise exception 'cannot deactivate the last owner'; end if;
  update profiles set is_active = p_active where id = p_user;
end $$;

-- ---------- privileges ----------
revoke execute on function _assert_user_admin(), _caller_is_top(), _is_top_user(uuid), _other_active_owner_exists(uuid, uuid), _check_roles(text[], uuid, uuid) from public, anon, authenticated;
revoke execute on function my_permissions(), list_users(), provision_user(text, text, text[], uuid, uuid, text), set_user_roles(uuid, text[]), set_user_active(uuid, boolean) from public, anon;
grant  execute on function my_permissions(), list_users(), provision_user(text, text, text[], uuid, uuid, text), set_user_roles(uuid, text[]), set_user_active(uuid, boolean) to authenticated;

commit;
