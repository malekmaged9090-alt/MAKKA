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
