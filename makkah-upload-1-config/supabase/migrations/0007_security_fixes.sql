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
