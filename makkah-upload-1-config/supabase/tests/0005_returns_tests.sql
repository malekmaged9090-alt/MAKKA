-- =====================================================================
-- Functional tests for 0005_returns_ops.sql
-- Run after: 00_phase1_harness.sql, 0003, 0004, 0005
-- =====================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

-- 0004 tests lock today's period; unlock for this scenario.
delete from financial_periods;

-- ---------- extra fixtures ----------
insert into auth.users (id, email) values
 ('aaaaaaaa-0000-0000-0000-000000000004', 'driver2@makkah.test'),
 ('aaaaaaaa-0000-0000-0000-000000000005', 'driver3@makkah.test');

insert into profiles (id, company_id, full_name, email) values
 ('aaaaaaaa-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Bilal Driver', 'driver2@makkah.test'),
 ('aaaaaaaa-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'Kareem Driver', 'driver3@makkah.test');

insert into user_roles (user_id, role_id) select 'aaaaaaaa-0000-0000-0000-000000000004', id from roles where code = 'driver';
insert into user_roles (user_id, role_id) select 'aaaaaaaa-0000-0000-0000-000000000005', id from roles where code = 'driver';

insert into drivers (id, company_id, user_id, full_name, phone, emirate_id, branch_id, status, commission_per_delivery)
values
 ('66666666-6666-6666-6666-666666666662', '11111111-1111-1111-1111-111111111111',
  'aaaaaaaa-0000-0000-0000-000000000004', 'Bilal Driver', '0509998802',
  '22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444', 'available', 5),
 ('66666666-6666-6666-6666-666666666663', '11111111-1111-1111-1111-111111111111',
  'aaaaaaaa-0000-0000-0000-000000000005', 'Kareem Driver', '0509998803',
  '22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444', 'available', 5);

insert into driver_area_assignments (driver_id, area_id)
values ('66666666-6666-6666-6666-666666666662', '33333333-3333-3333-3333-333333333333');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);

insert into shipments (id, company_id, merchant_id, customer_id, recipient_name, recipient_phone,
                       delivery_emirate_id, delivery_area_id, delivery_address_text, service_type,
                       parcel_count, weight_kg, goods_value, payment_method, cod_amount, created_by)
values
 ('88888888-8888-8888-8888-8888888888a1', '11111111-1111-1111-1111-111111111111',
  '55555555-5555-5555-5555-555555555555', '77777777-7777-7777-7777-777777777777',
  'Sara Customer', '0501234567', '22222222-2222-2222-2222-222222222222',
  '33333333-3333-3333-3333-333333333333', 'Deira, Return Street 1', 'same_day',
  1, 1.0, 100, 'cod', 100, 'aaaaaaaa-0000-0000-0000-000000000001'),
 ('88888888-8888-8888-8888-8888888888a2', '11111111-1111-1111-1111-111111111111',
  '55555555-5555-5555-5555-555555555555', '77777777-7777-7777-7777-777777777777',
  'Sara Customer', '0501234567', '22222222-2222-2222-2222-222222222222',
  '33333333-3333-3333-3333-333333333333', 'Deira, Reassign Street 2', 'same_day',
  1, 1.0, 100, 'cod', 100, 'aaaaaaaa-0000-0000-0000-000000000001'),
 ('88888888-8888-8888-8888-8888888888a3', '11111111-1111-1111-1111-111111111111',
  '55555555-5555-5555-5555-555555555555', '77777777-7777-7777-7777-777777777777',
  'Sara Customer', '0501234567', '22222222-2222-2222-2222-222222222222',
  '33333333-3333-3333-3333-333333333333', 'Deira, Scan Street 3', 'same_day',
  1, 1.0, 100, 'cod', 100, 'aaaaaaaa-0000-0000-0000-000000000001');

-- ---------- 1. return request ----------
do $$
declare v_ret uuid; v_status text; v_no text; v_blocked boolean := false;
begin
  foreach v_status in array array['CONFIRMED','PICKUP_REQUESTED','PICKED_UP'] loop
    perform change_shipment_status('88888888-8888-8888-8888-8888888888a1'::uuid, v_status, null, 'test');
  end loop;

  v_ret := create_return('88888888-8888-8888-8888-8888888888a1'::uuid, 'customer_cancelled', 'customer changed mind');
  select status, return_no into v_status, v_no from returns where id = v_ret;
  if v_status <> 'requested' then raise exception 'return status %', v_status; end if;
  if v_no not like 'RET-%' then raise exception 'return number %', v_no; end if;
  if (select status_code from shipments where id = '88888888-8888-8888-8888-8888888888a1') <> 'RETURN_TO_HUB' then
    raise exception 'shipment did not move to RETURN_TO_HUB';
  end if;

  begin
    perform create_return('88888888-8888-8888-8888-8888888888a1'::uuid, 'other');
  exception when others then
    if sqlerrm like '%active return already exists%' then v_blocked := true; else raise; end if;
  end;
  if not v_blocked then raise exception 'duplicate return was accepted'; end if;

  raise notice 'PASS 1: return % created, duplicate blocked', v_no;
end $$;

-- ---------- 2. receive -> inspect -> complete + return fee ----------
do $$
declare v_ret uuid; v_blocked boolean := false;
begin
  select id into v_ret from returns where shipment_id = '88888888-8888-8888-8888-8888888888a1';
  perform receive_return(v_ret, '44444444-4444-4444-4444-444444444444', 'received at hub');
  if (select status from returns where id = v_ret) <> 'received_at_hub' then raise exception 'receive failed'; end if;

  perform inspect_return(v_ret, 'good', 'box sealed');
  if (select status from returns where id = v_ret) <> 'inspected' then raise exception 'inspect failed'; end if;

  perform complete_return(v_ret);
  if (select status from returns where id = v_ret) <> 'returned_to_merchant' then raise exception 'complete failed'; end if;
  if (select status_code from shipments where id = '88888888-8888-8888-8888-8888888888a1') <> 'RETURN_TO_MERCHANT' then
    raise exception 'shipment did not move to RETURN_TO_MERCHANT';
  end if;
  if (select amount from merchant_ledger where shipment_id = '88888888-8888-8888-8888-8888888888a1' and entry_type = 'return_fee') <> 10 then
    raise exception 'return fee not posted';
  end if;

  begin
    perform complete_return(v_ret);
  exception when others then
    if sqlerrm like '%must be inspected%' then v_blocked := true; else raise; end if;
  end;
  if not v_blocked then raise exception 'double completion was accepted'; end if;

  raise notice 'PASS 2: return completed, 10 AED return fee posted, double completion blocked';
end $$;

-- ---------- 3. reassignment ----------
do $$
declare v_status text; v_manifest uuid; v_blocked boolean := false;
begin
  foreach v_status in array array['CONFIRMED','PICKUP_REQUESTED','PICKED_UP','RECEIVED_AT_HUB','SORTING','READY_FOR_DISPATCH'] loop
    perform change_shipment_status('88888888-8888-8888-8888-8888888888a2'::uuid, v_status, null, 'test');
  end loop;

  perform assign_shipments('66666666-6666-6666-6666-666666666666'::uuid,
                           array['88888888-8888-8888-8888-8888888888a2'::uuid]);
  if (select driver_id from shipment_assignments where shipment_id = '88888888-8888-8888-8888-8888888888a2' and is_current)
     <> '66666666-6666-6666-6666-666666666666' then raise exception 'initial assignment failed'; end if;

  begin
    perform reassign_shipment_ext('88888888-8888-8888-8888-8888888888a2'::uuid,
                                  '66666666-6666-6666-6666-666666666662'::uuid, '');
  exception when others then
    if sqlerrm like '%reason required%' then v_blocked := true; else raise; end if;
  end;
  if not v_blocked then raise exception 'reassignment without reason accepted'; end if;

  v_manifest := reassign_shipment_ext('88888888-8888-8888-8888-8888888888a2'::uuid,
                                      '66666666-6666-6666-6666-666666666662'::uuid, 'driver shift ended');
  if (select driver_id from shipment_assignments where shipment_id = '88888888-8888-8888-8888-8888888888a2' and is_current)
     <> '66666666-6666-6666-6666-666666666662' then raise exception 'reassignment failed'; end if;
  if (select count(*) from shipment_assignments where shipment_id = '88888888-8888-8888-8888-8888888888a2') <> 2 then
    raise exception 'assignment history not preserved';
  end if;
  if not exists (select 1 from shipment_status_events where shipment_id = '88888888-8888-8888-8888-8888888888a2' and note like 'reassigned to%') then
    raise exception 'reassignment not audited';
  end if;

  begin
    perform reassign_shipment_ext('88888888-8888-8888-8888-8888888888a2'::uuid,
                                  '66666666-6666-6666-6666-666666666663'::uuid, 'no coverage test');
  exception when others then
    if sqlerrm like '%does not cover%' then v_blocked := true; else raise; end if;
  end;
  if not v_blocked then raise exception 'driver without coverage accepted'; end if;

  raise notice 'PASS 3: reassignment to covered driver, history + audit kept, coverage enforced';
end $$;

-- ---------- 4. bulk scan ----------
do $$
declare r jsonb; v_status text;
begin
  foreach v_status in array array['CONFIRMED','PICKUP_REQUESTED','PICKED_UP'] loop
    perform change_shipment_status('88888888-8888-8888-8888-8888888888a3'::uuid, v_status, null, 'test');
  end loop;

  r := bulk_scan(array[
        (select serial_number from shipments where id = '88888888-8888-8888-8888-8888888888a3'),
        (select serial_number from shipments where id = '88888888-8888-8888-8888-8888888888a3'),
        'MKK-NOT-EXIST'], 'receive_at_hub', '44444444-4444-4444-4444-444444444444');

  if (r->>'ok')::int <> 1 then raise exception 'expected 1 ok, got %', r->>'ok'; end if;
  if (r->>'duplicates')::int <> 1 then raise exception 'expected 1 duplicate, got %', r->>'duplicates'; end if;
  if (r->>'not_found')::int <> 1 then raise exception 'expected 1 not found, got %', r->>'not_found'; end if;
  if (select status_code from shipments where id = '88888888-8888-8888-8888-8888888888a3') <> 'RECEIVED_AT_HUB' then
    raise exception 'receive scan did not move status';
  end if;
  if (select count(*) from shipment_scans where shipment_id = '88888888-8888-8888-8888-8888888888a3' and scan_type = 'receive_at_hub') <> 1 then
    raise exception 'duplicate scan row persisted';
  end if;

  r := bulk_scan(array[(select serial_number from shipments where id = '88888888-8888-8888-8888-8888888888a3')], 'sorting');
  if (r->>'ok')::int <> 1 then raise exception 'sorting scan failed'; end if;
  if (select status_code from shipments where id = '88888888-8888-8888-8888-8888888888a3') <> 'SORTING' then
    raise exception 'sorting status not applied';
  end if;

  r := bulk_scan(array[(select serial_number from shipments where id = '88888888-8888-8888-8888-8888888888a3')], 'receive_at_hub');
  if (r->>'rejected')::int <> 1 then raise exception 'wrong-status scan was accepted'; end if;

  raise notice 'PASS 4: bulk scan ok/duplicate/not_found/wrong_status all correct';
end $$;

-- ---------- 5. manifest close ----------
do $$
declare v_manifest uuid; r jsonb; v_blocked boolean := false;
begin
  select manifest_id into v_manifest from shipment_assignments
   where shipment_id = '88888888-8888-8888-8888-8888888888a2' and is_current;

  r := close_manifest(v_manifest);
  if (r->>'total')::int <> 1 then raise exception 'manifest total %', r->>'total'; end if;
  if (select status from dispatch_manifests where id = v_manifest) <> 'closed' then raise exception 'manifest not closed'; end if;

  begin
    perform close_manifest(v_manifest);
  exception when others then
    if sqlerrm like '%already closed%' then v_blocked := true; else raise; end if;
  end;
  if not v_blocked then raise exception 'double close accepted'; end if;

  raise notice 'PASS 5: manifest closed with totals, double close blocked';
end $$;

do $$ begin raise notice 'ALL PHASE 4 TESTS PASSED'; end $$;
