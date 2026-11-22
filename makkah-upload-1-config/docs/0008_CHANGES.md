# What changed vs. `makkah-delivery-final.zip`

| # | Problem found | Fix |
|---|---|---|
| 1 | The zip's `0001/0002` were stand-ins with **no RLS** (24 tables exposed through the public anon key) | Restored the original `0001_core_schema.sql` / `0002_seed_and_rls.sql` (full RLS). `0002_rbac_statuses.sql` removed. |
| 2 | `0006` failed on the original schema (`notifications` table missing) | `0006` now creates it idempotently |
| 3 | **Every SELECT on `shipments` failed** with "infinite recursion in policy" (0003 driver policy <-> 0007 assignments policy) | `0008` §6: `is_my_assigned_shipment()` SECURITY DEFINER helper + rewritten policy |
| 4 | Anonymous visitors could execute ~75 functions (incl. `resolve_delivery_fee`, `assert_period_open`) | `0008` §1: revoked from PUBLIC/anon; only `public_tracking` remains; default privileges tightened |
| 5 | `auto_dispatch` counted delivered shipments as driver load | `0008` §2 + dispatch page now count only ASSIGNED_TO_DRIVER / OUT_FOR_DELIVERY |
| 6 | `bulk_scan` used `shipment_parcels.serial_number` (real column: `parcel_serial`) and wrote scan_context values the Phase 1 CHECK rejects | Fixed in `0005` and repaired in `0008` §4 |
| 7 | `report_rows('barcode_reprints')` used `barcode_print_logs.company_id` (does not exist) | Fixed in `0006` and repaired in `0008` §5 |
| 8 | `notification_deliveries` had a policy but RLS was never enabled | `0008` §3 enables RLS on any public table that lacks it (deny by default) |
| 9 | Stale psql harness / `run.sh` / docs | Replaced by `npm run test:db` (61 tests on real PostgreSQL via PGlite) and `supabase/verify_production.sql` |

`0008` is idempotent and also repairs a database that already ran the old `0005`/`0006`/`0007`.

# 0009 (new in this release)

| Change | Why |
|---|---|
| `profiles` / `user_roles` policies rewritten: company-scoped reads, **no direct writes** | The old `users.manage` policies had no company filter (cross-company read/write) and allowed direct self-escalation |
| `provision_user`, `set_user_roles`, `set_user_active`, `list_users`, `my_permissions` | Users screen without a service_role key; owner-only escalation, no self-edit, last-owner protection, audit |
| New screens: `/areas`, `/areas/import`, `/shipments/import`, `/customers`, `/users` | Everything listed as "not built yet" |
