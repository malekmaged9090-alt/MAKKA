# MAKKAH DELIVERY — TODO

## Done and verified by automated tests (`npm test`)
- [x] Core schema with RLS on every table (0001/0002), drivers/dispatch (0003), finance/COD (0004), returns/ops (0005), reports/notifications (0006)
- [x] 0007 security fixes + **0008 hardening**: anonymous visitors can only call `public_tracking`; fixed infinite RLS recursion on `shipments`; dispatch load ignores delivered shipments; fixed `bulk_scan` (parcel column + scan_context vocabulary) and the `barcode_reprints` report against the Phase 1 schema
- [x] Automated RLS tests: tenant isolation, merchant isolation, driver visibility, anon access, role escalation, append-only audit
- [x] Type check and production build

## Before go-live (needs YOUR Supabase project / decisions)
- [ ] Run 01_ALL_IN_ONE.sql, then `supabase/verify_production.sql` (all queries must return 0 rows)
- [ ] Create the first owner (see README step 4) and test the real flows in a browser: create shipment, print waybill, dispatch, driver delivery, settlement
- [ ] Configure `.env.local` / Netlify environment variables (URL, anon key, site URL). Never put `service_role` in the app
- [ ] Add rate limiting for `/track` (public endpoint) at the CDN/edge
- [ ] Configure an email/SMS/WhatsApp provider before enabling external notification channels
- [ ] Review UAE privacy, retention and VAT policies with the owner/accountant
- [ ] Backups, monitoring, and a separate staging project

## Built since the first release
- [x] Areas management (cover / disable / needs-review) + Excel import with preview
- [x] Shipments Excel import (preview, validation, duplicate protection, atomic, safe to re-submit)
- [x] Customers page (search, detail, edit, history)
- [x] Users & roles screen (link an Auth account, roles, deactivate; owner-only escalation; last-owner protection)
- [x] Navigation shows only what the signed-in user may use
- [x] One-paste setup files: 00_RESET, 01_ALL_IN_ONE, 02_bootstrap_admin (all tested)

## Still not covered by automated tests
- [ ] Browser/end-to-end flows (the database layer and the import logic are tested; screens are not clicked through automatically)
- [ ] Real Supabase (Auth emails, Storage, rate limits) — verify with `supabase/verify_production.sql` and a manual smoke test (DEPLOY_AR.md, last section)
