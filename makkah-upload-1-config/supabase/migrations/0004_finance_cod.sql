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
