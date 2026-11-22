-- =====================================================================
-- MAKKAH DELIVERY - 0009_users_admin.sql
-- User & role administration from the app (no service_role key needed in the app):
--   * profiles / user_roles are no longer writable directly by anyone; all changes go through
--     guarded functions that enforce company scope, owner-only escalation and last-owner protection.
--   * Fixes a cross-company hole: the old users.manage policies had no company filter.
--   * my_permissions() lets the UI show only what the signed-in user may use.
-- Auth accounts themselves are created in Supabase Auth (Dashboard > Authentication > Users);
-- the app then links the account to this company with provision_user().
-- =====================================================================

-- ---------- policies: company-scoped reads, no direct writes ----------
drop policy if exists profiles_admin on profiles;
drop policy if exists profiles_self  on profiles;
create policy profiles_self on profiles for select to authenticated using (id = auth.uid());
create policy profiles_admin_read on profiles for select to authenticated
  using (company_id = current_company_id() and has_permission('users.manage'));

drop policy if exists userroles_admin on user_roles;
drop policy if exists userroles_read  on user_roles;
create policy userroles_read on user_roles for select to authenticated using (
  user_id = auth.uid()
  or (has_permission('users.manage') and exists (select 1 from profiles p where p.id = user_roles.user_id and p.company_id = current_company_id())));

drop trigger if exists trg_audit_profiles on profiles;
create trigger trg_audit_profiles after insert or update or delete on profiles for each row execute function audit_row();

-- ---------- internal helpers (not callable by clients) ----------
create or replace function _assert_user_admin() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not has_permission('users.manage') then raise exception 'permission users.manage required'; end if;
end $$;

create or replace function _caller_is_top() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles pr join user_roles ur on ur.user_id = pr.id join roles r on r.id = ur.role_id
                 where pr.id = auth.uid() and pr.is_active and r.code in ('owner','super_admin'))
$$;

create or replace function _is_top_user(p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_roles ur join roles r on r.id = ur.role_id where ur.user_id = p_user and r.code in ('owner','super_admin'))
$$;

create or replace function _other_active_owner_exists(p_company uuid, p_except uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles pr join user_roles ur on ur.user_id = pr.id join roles r on r.id = ur.role_id
                 where pr.company_id = p_company and pr.is_active and pr.id <> p_except and r.code in ('owner','super_admin'))
$$;

create or replace function _check_roles(p_roles text[], p_merchant uuid, p_company uuid) returns void language plpgsql stable security definer set search_path = public as $$
declare r text; v_merchant_roles text[] := array['merchant_admin','merchant_employee']; v_has_m boolean; v_has_staff boolean;
begin
  if p_roles is null or cardinality(p_roles) = 0 then raise exception 'at least one role is required'; end if;
  foreach r in array p_roles loop
    if not exists (select 1 from roles where code = r) then raise exception 'unknown role %', r; end if;
  end loop;
  if (p_roles && array['owner','super_admin']) and not _caller_is_top() then
    raise exception 'only an owner can grant the owner role';
  end if;
  v_has_m := p_roles && v_merchant_roles;
  v_has_staff := exists (select 1 from unnest(p_roles) x where x <> all (v_merchant_roles));
  if v_has_m and v_has_staff then raise exception 'merchant roles cannot be combined with staff roles'; end if;
  if v_has_m and p_merchant is null then raise exception 'a merchant is required for merchant roles'; end if;
  if not v_has_m and p_merchant is not null then raise exception 'merchant can only be set for merchant roles'; end if;
  if p_merchant is not null and not exists (select 1 from merchants where id = p_merchant and company_id = p_company) then
    raise exception 'merchant not found';
  end if;
end $$;

-- ---------- app-facing functions ----------
create or replace function my_permissions() returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct pm.code), '{}')
  from profiles pr join user_roles ur on ur.user_id = pr.id join role_permissions rp on rp.role_id = ur.role_id join permissions pm on pm.id = rp.permission_id
  where pr.id = auth.uid() and pr.is_active
$$;

create or replace function list_users() returns table (
  id uuid, email text, full_name text, phone text, is_active boolean, merchant_id uuid, merchant_name text,
  roles text[], last_sign_in_at timestamptz, created_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  perform _assert_user_admin();
  return query
    select pr.id, au.email::text, pr.full_name, pr.phone, pr.is_active, pr.merchant_id, m.name,
           coalesce((select array_agg(r.code order by r.code) from user_roles ur join roles r on r.id = ur.role_id where ur.user_id = pr.id), '{}'),
           au.last_sign_in_at, pr.created_at
    from profiles pr left join auth.users au on au.id = pr.id left join merchants m on m.id = pr.merchant_id
    where pr.company_id = current_company_id()
    order by pr.is_active desc, pr.full_name;
end $$;

create or replace function provision_user(p_email text, p_full_name text, p_roles text[], p_merchant uuid default null,
                                          p_branch uuid default null, p_phone text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); v_user uuid; v_existing uuid;
begin
  perform _assert_user_admin();
  if coalesce(trim(p_full_name), '') = '' then raise exception 'full name is required'; end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'no auth account with this email; create it first in Supabase Authentication > Users';
  end if;
  select company_id into v_existing from profiles where id = v_user;
  if v_existing is not null then raise exception 'this account is already registered; edit its roles instead'; end if;
  perform _check_roles(p_roles, p_merchant, v_company);
  if p_branch is not null and not exists (select 1 from branches where id = p_branch and company_id = v_company) then raise exception 'branch not found'; end if;
  insert into profiles (id, company_id, full_name, phone, branch_id, merchant_id)
  values (v_user, v_company, trim(p_full_name), nullif(trim(coalesce(p_phone, '')), ''), p_branch, p_merchant);
  insert into user_roles (user_id, role_id) select v_user, id from roles where code = any (p_roles);
  return v_user;
end $$;

create or replace function set_user_roles(p_user uuid, p_roles text[]) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id(); t record;
begin
  perform _assert_user_admin();
  select * into t from profiles where id = p_user and company_id = v_company;
  if not found then raise exception 'user not found'; end if;
  if p_user = auth.uid() then raise exception 'you cannot change your own roles'; end if;
  if _is_top_user(p_user) and not _caller_is_top() then raise exception 'only an owner can change an owner'; end if;
  perform _check_roles(p_roles, t.merchant_id, v_company);
  if _is_top_user(p_user) and not (p_roles && array['owner','super_admin']) and not _other_active_owner_exists(v_company, p_user) then
    raise exception 'cannot remove the last owner';
  end if;
  delete from user_roles where user_id = p_user;
  insert into user_roles (user_id, role_id) select p_user, id from roles where code = any (p_roles);
end $$;

create or replace function set_user_active(p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_company uuid := current_company_id();
begin
  perform _assert_user_admin();
  if not exists (select 1 from profiles where id = p_user and company_id = v_company) then raise exception 'user not found'; end if;
  if p_user = auth.uid() then raise exception 'you cannot deactivate yourself'; end if;
  if _is_top_user(p_user) and not _caller_is_top() then raise exception 'only an owner can change an owner'; end if;
  if not p_active and _is_top_user(p_user) and not _other_active_owner_exists(v_company, p_user) then raise exception 'cannot deactivate the last owner'; end if;
  update profiles set is_active = p_active where id = p_user;
end $$;

-- ---------- privileges ----------
revoke execute on function _assert_user_admin(), _caller_is_top(), _is_top_user(uuid), _other_active_owner_exists(uuid, uuid), _check_roles(text[], uuid, uuid) from public, anon, authenticated;
revoke execute on function my_permissions(), list_users(), provision_user(text, text, text[], uuid, uuid, text), set_user_roles(uuid, text[]), set_user_active(uuid, boolean) from public, anon;
grant  execute on function my_permissions(), list_users(), provision_user(text, text, text[], uuid, uuid, text), set_user_roles(uuid, text[]), set_user_active(uuid, boolean) to authenticated;
