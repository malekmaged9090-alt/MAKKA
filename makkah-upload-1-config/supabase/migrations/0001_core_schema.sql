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
