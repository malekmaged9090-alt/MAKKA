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
