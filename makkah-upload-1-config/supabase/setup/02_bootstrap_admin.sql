-- =====================================================================
-- Creates the company (first run only) and makes ONE existing Auth user the OWNER.
-- 1) Authentication > Users > Add user (email + password, tick "Auto Confirm User").
-- 2) Replace the placeholder email on the v_email line below with that same email, then Run.
-- You must see:  NOTICE: Owner ready: ...      Safe to run again.
-- =====================================================================
do $$
declare
  v_email text := 'CHANGE_ME@example.com';
  v_user uuid; v_company uuid;
begin
  if v_email like 'CHANGE_ME%' then raise exception 'Edit v_email first (use the email of the user you created in Authentication)'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(v_email));
  if v_user is null then raise exception 'No Authentication user with email %. Create it first: Authentication > Users > Add user', v_email; end if;
  select id into v_company from companies order by created_at limit 1;
  if v_company is null then
    insert into companies (code, name_ar, name_en) values ('MKK', 'شركة مكة للتوصيل', 'MAKKAH DELIVERY') returning id into v_company;
  end if;
  insert into profiles (id, company_id, full_name) values (v_user, v_company, 'Owner')
  on conflict (id) do update set is_active = true;
  insert into user_roles (user_id, role_id) select v_user, id from roles where code = 'owner' on conflict do nothing;
  raise notice 'Owner ready: % (company %)', v_email, v_company;
end $$;
