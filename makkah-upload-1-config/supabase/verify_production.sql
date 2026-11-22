-- Run in the Supabase SQL Editor AFTER applying all migrations. Every query below must return ZERO rows.

-- 1) tables without Row Level Security (must be empty)
select c.relname as table_without_rls
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;

-- 2) functions the anonymous (not signed-in) visitor can run: only public_tracking is allowed
select p.proname as anon_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind = 'f' and p.prorettype::regtype::text <> 'trigger'
  and has_function_privilege('anon', p.oid, 'execute')
  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  and p.proname <> 'public_tracking';

-- 3) internal helper functions (names starting with _) callable by signed-in users: must be empty
select p.proname as internal_function_exposed
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like '\_%' and has_function_privilege('authenticated', p.oid, 'execute');

-- 4) all migrations applied? expect these helper objects to exist (0 rows = all present)
select x as missing_object from unnest(array['is_my_assigned_shipment','report_rows','bulk_scan','public_tracking','change_shipment_status']) x
where not exists (select 1 from pg_proc where proname = x);
