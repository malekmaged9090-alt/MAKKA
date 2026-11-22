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
