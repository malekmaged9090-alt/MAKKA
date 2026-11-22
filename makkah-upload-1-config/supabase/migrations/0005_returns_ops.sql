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
