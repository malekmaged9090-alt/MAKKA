-- =====================================================================
-- Functional tests for 0004_finance_cod.sql
-- Run after: 00_phase1_harness.sql, 0003, 0004
-- Every block raises on failure; the script ends with a summary.
-- =====================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

-- ---------- fixtures ----------
insert into companies (id, code, name_ar, name_en, vat_enabled, vat_rate)
values ('11111111-1111-1111-1111-111111111111', 'MKK', 'شركة مكة للتوصيل', 'MAKKAH DELIVERY', true, 5);

insert into emirates (id, code, name_ar, name_en)
values ('22222222-2222-2222-2222-222222222222', 'DXB', 'دبي', 'Dubai');

insert into areas (id, emirate_id, name_ar, name_en)
values ('33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222', 'ديرة', 'Deira');

insert into branches (id, company_id, code, name_ar, name_en, emirate_id, area_id)
values ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111', 'DXB1', 'فرع ديرة', 'Deira Hub',
        '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333');

insert into merchants (id, company_id, name, phone, emirate_id, area_id, delivery_fee, return_fee, extra_attempt_fee, cod_fee_percent)
values ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111', 'Noon Traders', '0501112233',
        '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333', 20, 10, 5, 1);

insert into auth.users (id, email) values
 ('aaaaaaaa-0000-0000-0000-000000000001', 'owner@makkah.test'),
 ('aaaaaaaa-0000-0000-0000-000000000002', 'accountant@makkah.test'),
 ('aaaaaaaa-0000-0000-0000-000000000003', 'driver@makkah.test');

insert into profiles (id, company_id, full_name, email) values
 ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Owner', 'owner@makkah.test'),
 ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Accountant', 'accountant@makkah.test'),
 ('aaaaaaaa-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Ahmed Driver', 'driver@makkah.test');

insert into user_roles (user_id, role_id) select 'aaaaaaaa-0000-0000-0000-000000000001', id from roles where code = 'owner';
insert into user_roles (user_id, role_id) select 'aaaaaaaa-0000-0000-0000-000000000002', id from roles where code = 'accountant';
insert into user_roles (user_id, role_id) select 'aaaaaaaa-0000-0000-0000-000000000003', id from roles where code = 'driver';

insert into drivers (id, company_id, user_id, full_name, phone, emirate_id, branch_id, status, commission_per_delivery)
values ('66666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-0000-0000-0000-000000000003', 'Ahmed Driver', '0509998877',
        '22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444', 'available', 5);

insert into driver_area_assignments (driver_id, area_id)
values ('66666666-6666-6666-6666-666666666666', '33333333-3333-3333-3333-333333333333');

insert into customers (id, company_id, full_name, phone, emirate_id, area_id)
values ('77777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111', 'Sara Customer', '0501234567',
        '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333');

-- ---------- 1. shipment + fee snapshot ----------
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);

insert into shipments (id, company_id, merchant_id, customer_id, recipient_name, recipient_phone,
                       delivery_emirate_id, delivery_area_id, delivery_address_text, service_type,
                       parcel_count, weight_kg, goods_value, payment_method, cod_amount, created_by)
values ('88888888-8888-8888-8888-888888888888', '11111111-1111-1111-1111-111111111111',
        '55555555-5555-5555-5555-555555555555', '77777777-7777-7777-7777-777777777777',
        'Sara Customer', '0501234567', '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333', 'Deira, Baniyas Road, Building 12', 'same_day',
        1, 2.4, 300, 'cod', 300, 'aaaaaaaa-0000-0000-0000-000000000001');

do $$
declare s record;
begin
  select * into s from shipments where id = '88888888-8888-8888-8888-888888888888';
  if s.serial_number is null or s.serial_number not like 'MKK-%' then raise exception 'serial not generated'; end if;
  if s.delivery_fee <> 20 then raise exception 'expected fee 20, got %', s.delivery_fee; end if;
  if s.vat_amount <> 1.00 then raise exception 'expected VAT 1.00, got %', s.vat_amount; end if;
  if s.fees_calculated_at is null then raise exception 'fee snapshot missing'; end if;
  raise notice 'PASS 1: serial=% fee=% vat=%', s.serial_number, s.delivery_fee, s.vat_amount;
end $$;

-- ---------- 2. lifecycle to ready for dispatch ----------
do $$
declare v text;
begin
  foreach v in array array['CONFIRMED','PICKUP_REQUESTED','PICKED_UP','RECEIVED_AT_HUB','SORTING','READY_FOR_DISPATCH'] loop
    perform change_shipment_status('88888888-8888-8888-8888-888888888888'::uuid, v, null, 'test');
  end loop;
  if (select status_code from shipments where id = '88888888-8888-8888-8888-888888888888') <> 'READY_FOR_DISPATCH' then
    raise exception 'lifecycle failed';
  end if;
  raise notice 'PASS 2: lifecycle to READY_FOR_DISPATCH';
end $$;

-- ---------- 3. dispatch + driver app ----------
do $$
declare m uuid;
begin
  m := assign_shipments('66666666-6666-6666-6666-666666666666'::uuid, array['88888888-8888-8888-8888-888888888888']::uuid[]);
  if m is null then raise exception 'manifest not created'; end if;
  if (select count(*) from shipment_assignments where shipment_id = '88888888-8888-8888-8888-888888888888' and is_current) <> 1 then
    raise exception 'assignment missing';
  end if;
  raise notice 'PASS 3: dispatch manifest %', m;
end $$;

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000003', false);
select driver_accept('88888888-8888-8888-8888-888888888888'::uuid);
select driver_out_for_delivery('88888888-8888-8888-8888-888888888888'::uuid);

-- ---------- 4. delivery posts COD + fees + commission ----------
select driver_deliver('88888888-8888-8888-8888-888888888888'::uuid, 'Sara Customer', 300, 'cash', null);

do $$
declare v_cod numeric; v_cash numeric; v_dues numeric; v_net numeric; v_commission numeric;
begin
  select amount into v_cod from cod_transactions where shipment_id = '88888888-8888-8888-8888-888888888888';
  select coalesce(sum(direction*amount),0) into v_cash from driver_ledger where driver_id = '66666666-6666-6666-6666-666666666666' and account = 'cash';
  select coalesce(sum(direction*amount),0) into v_dues from driver_ledger where driver_id = '66666666-6666-6666-6666-666666666666' and account = 'dues';
  select coalesce(sum(direction*amount),0) into v_net from merchant_ledger where merchant_id = '55555555-5555-5555-5555-555555555555';
  select amount into v_commission from driver_ledger where driver_id = '66666666-6666-6666-6666-666666666666' and entry_type = 'commission';

  if v_cod <> 300 then raise exception 'COD ledger expected 300, got %', v_cod; end if;
  if v_cash <> 300 then raise exception 'driver cash expected 300, got %', v_cash; end if;
  if v_commission <> 5 then raise exception 'commission expected 5, got %', v_commission; end if;
  if v_net <> 276 then raise exception 'merchant net expected 276 (300-20-1-3), got %', v_net; end if;
  if (select status_code from shipments where id = '88888888-8888-8888-8888-888888888888') <> 'DELIVERED' then
    raise exception 'shipment not delivered';
  end if;
  raise notice 'PASS 4: COD=%, cash=%, dues=%, merchant net=%', v_cod, v_cash, v_dues, v_net;
end $$;

-- duplicate delivery must be rejected by the status engine
do $$
begin
  begin
    perform driver_deliver('88888888-8888-8888-8888-888888888888'::uuid, 'Sara Customer', 300, 'cash', null);
    raise exception 'duplicate delivery was accepted';
  exception when others then
    if sqlerrm = 'duplicate delivery was accepted' then raise; end if;
    raise notice 'PASS 5: duplicate delivery rejected (%)', sqlerrm;
  end;
end $$;

-- ---------- 6. cash handover + idempotency ----------
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select record_cash_handover('66666666-6666-6666-6666-666666666666', 300, 'RC-1', null,
                            '99999999-9999-9999-9999-999999999999');
select record_cash_handover('66666666-6666-6666-6666-666666666666', 300, 'RC-1', null,
                            '99999999-9999-9999-9999-999999999999');

do $$
declare v_cash numeric; v_handed numeric; v_rows int;
begin
  select coalesce(sum(direction*amount),0) into v_cash from driver_ledger where driver_id = '66666666-6666-6666-6666-666666666666' and account = 'cash';
  select coalesce(sum(handed_amount),0) into v_handed from cod_transactions where driver_id = '66666666-6666-6666-6666-666666666666';
  select count(*) into v_rows from driver_ledger where driver_id = '66666666-6666-6666-6666-666666666666' and entry_type = 'cash_handover';
  if v_cash <> 0 then raise exception 'cash after handover expected 0, got %', v_cash; end if;
  if v_handed <> 300 then raise exception 'COD handed expected 300, got %', v_handed; end if;
  if v_rows <> 1 then raise exception 'idempotency failed: % handover rows', v_rows; end if;
  raise notice 'PASS 6: handover cleared custody, replay ignored';
end $$;

-- handover above custody must fail
do $$
begin
  begin
    perform record_cash_handover('66666666-6666-6666-6666-666666666666', 1, 'RC-2', null, null);
    raise exception 'over-handover was accepted';
  exception when others then
    if sqlerrm = 'over-handover was accepted' then raise; end if;
    raise notice 'PASS 7: over-handover rejected (%)', sqlerrm;
  end;
end $$;

-- ---------- 8. settlement: create -> SOD -> approve -> pay ----------
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select create_merchant_settlement('55555555-5555-5555-5555-555555555555',
                                  (now() at time zone 'Asia/Dubai')::date,
                                  (now() at time zone 'Asia/Dubai')::date,
                                  'daily settlement');

do $$
declare s record;
begin
  select * into s from merchant_settlements where merchant_id = '55555555-5555-5555-5555-555555555555';
  if s.net_payable <> 276 then raise exception 'settlement net expected 276, got %', s.net_payable; end if;
  if s.cod_total <> 300 or s.delivery_fees <> 20 or s.vat_total <> 1 or s.cod_fees <> 3 then
    raise exception 'settlement breakdown wrong: %', row_to_json(s);
  end if;
  if s.status <> 'draft' then raise exception 'expected draft'; end if;
  raise notice 'PASS 8: settlement % net=%', s.settlement_no, s.net_payable;
end $$;

-- creator cannot approve their own settlement
do $$
begin
  begin
    perform approve_merchant_settlement((select id from merchant_settlements where merchant_id = '55555555-5555-5555-5555-555555555555'));
    raise exception 'self-approval was accepted';
  exception when others then
    if sqlerrm = 'self-approval was accepted' then raise; end if;
    raise notice 'PASS 9: self-approval blocked (%)', sqlerrm;
  end;
end $$;

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select submit_merchant_settlement((select id from merchant_settlements where merchant_id = '55555555-5555-5555-5555-555555555555'));
select approve_merchant_settlement((select id from merchant_settlements where merchant_id = '55555555-5555-5555-5555-555555555555'));
select pay_merchant_settlement((select id from merchant_settlements where merchant_id = '55555555-5555-5555-5555-555555555555'), 'bank', 'TRX-1', null);

do $$
declare s record; v_balance numeric; v_pay numeric;
begin
  select * into s from merchant_settlements where merchant_id = '55555555-5555-5555-5555-555555555555';
  select coalesce(sum(direction*amount),0) into v_balance from merchant_ledger where merchant_id = '55555555-5555-5555-5555-555555555555';
  select amount into v_pay from payments where settlement_id = s.id;
  if s.status <> 'paid' then raise exception 'settlement not paid (%)', s.status; end if;
  if v_balance <> 0 then raise exception 'merchant balance after payment expected 0, got %', v_balance; end if;
  if v_pay <> 276 then raise exception 'payment expected 276, got %', v_pay; end if;
  raise notice 'PASS 10: settlement paid, merchant balance cleared';
end $$;

-- ---------- 11. invoice ----------
select create_invoice_from_settlement((select id from merchant_settlements where merchant_id = '55555555-5555-5555-5555-555555555555'));
do $$
declare i record;
begin
  select * into i from invoices where merchant_id = '55555555-5555-5555-5555-555555555555';
  if i.subtotal <> 23 then raise exception 'invoice subtotal expected 23, got %', i.subtotal; end if;
  if i.total <> 24 then raise exception 'invoice total expected 24, got %', i.total; end if;
  if i.invoice_no not like 'INV-%' then raise exception 'invoice numbering wrong: %', i.invoice_no; end if;
  raise notice 'PASS 11: invoice % total=%', i.invoice_no, i.total;
end $$;

-- ---------- 12. driver session close ----------
do $$
declare v_diff numeric; v_status text;
begin
  v_diff := close_driver_cash_session(
    (select id from driver_cash_sessions where driver_id = '66666666-6666-6666-6666-666666666666' order by business_date desc limit 1),
    0, null);
  if v_diff <> 0 then raise exception 'expected zero difference, got %', v_diff; end if;
  select status into v_status from driver_cash_sessions where driver_id = '66666666-6666-6666-6666-666666666666' order by business_date desc limit 1;
  if v_status <> 'closed' then raise exception 'session not closed'; end if;
  raise notice 'PASS 12: cash session closed, difference 0';
end $$;

-- ---------- 13. append-only ----------
do $$
begin
  begin
    update merchant_ledger set amount = 1 where merchant_id = '55555555-5555-5555-5555-555555555555' and entry_type = 'delivery_fee';
    raise exception 'ledger update was accepted';
  exception when others then
    if sqlerrm = 'ledger update was accepted' then raise; end if;
    raise notice 'PASS 13: ledger mutation blocked (%)', sqlerrm;
  end;

  begin
    delete from cod_transactions where shipment_id = '88888888-8888-8888-8888-888888888888';
    raise exception 'ledger delete was accepted';
  exception when others then
    if sqlerrm = 'ledger delete was accepted' then raise; end if;
    raise notice 'PASS 14: ledger delete blocked (%)', sqlerrm;
  end;
end $$;

-- ---------- 15. period lock ----------
insert into financial_periods(company_id, period_start, period_end, status, locked_by, locked_at)
values ('11111111-1111-1111-1111-111111111111', (now() at time zone 'Asia/Dubai')::date,
        (now() at time zone 'Asia/Dubai')::date, 'locked', 'aaaaaaaa-0000-0000-0000-000000000002', now());

do $$
begin
  begin
    perform record_expense('fuel', 100, 'test', 0, 'bank', null, null, (now() at time zone 'Asia/Dubai')::date, null);
    raise exception 'posting into a locked period was accepted';
  exception when others then
    if sqlerrm = 'posting into a locked period was accepted' then raise; end if;
    raise notice 'PASS 15: locked period rejected posting (%)', sqlerrm;
  end;
end $$;

-- ---------- summary ----------
do $$
begin
  raise notice '---------------------------------------------';
  raise notice 'ALL FINANCE TESTS PASSED';
  raise notice '---------------------------------------------';
end $$;
