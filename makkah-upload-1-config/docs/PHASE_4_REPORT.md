# PHASE 4 REPORT — Returns, Reassignment, Bulk Scanning

**Date:** 2026-11-20
**Migration:** `supabase/migrations/0005_returns_ops.sql`
**Tests:** `supabase/tests/0005_returns_tests.sql` (5 scenarios, all passing)

## What was delivered

### 1. Returns lifecycle
Table `returns` with a strict state machine:

```
requested → received_at_hub → inspected → returned_to_merchant
     └────────────── cancelled ──────────────┘
```

RPCs (all `security definer`, permission-checked, `search_path = public`):

| Function | Permission | Effect |
|---|---|---|
| `create_return(shipment, reason, note, type, branch)` | `returns.manage` | Creates the return and moves the shipment to `RETURN_TO_HUB` |
| `receive_return(return, branch, note)` | `returns.manage` | Marks arrival at the hub |
| `inspect_return(return, condition, note)` | `returns.complete` | Records `good` / `damaged` / `missing_items` |
| `complete_return(return)` | `returns.complete` | Moves the shipment to `RETURN_TO_MERCHANT`; 0004 posts the merchant return fee |
| `cancel_return(return, reason)` | `returns.manage` | Cancels before inspection |

Guarantees:
- One active return per shipment (partial unique index `returns_one_active_per_shipment`).
- Sequential-only transitions; double completion and double cancellation are rejected.
- Return numbers from `next_doc_no(company, 'RET')` → `RET-YYYY-NNNNNN`.
- Reason is mandatory; every step records user + timestamp.

### 2. Reassignment
`reassign_shipment_ext(shipment, driver, reason)`:
- Allowed from `ASSIGNED_TO_DRIVER`, `OUT_FOR_DELIVERY`, `RESCHEDULED` (0003 only covered the first).
- Mandatory reason.
- Driver must be active and cover the delivery area unless the user has `dispatch.override_area`.
- Closes the previous assignment (`is_current = false`, `unassigned_at`), creates a new manifest and assignment, and writes an audit event (`reassigned to <driver>`).
- `RESCHEDULED` shipments move back to `ASSIGNED_TO_DRIVER`; out-for-delivery shipments keep their status with the new driver.

UI: reassignment form on `/shipments/[id]` and an inline reassign action for every current assignment on `/dispatch`.

### 3. Bulk scanning
`shipment_scans` (existing Phase 1 table) was extended with `company_id`, `scan_type`, `batch_id`, `branch_id`, `driver_id`, `note`, `device`. A unique index on `(shipment_id, scan_type, batch_id)` makes a scan idempotent within its batch.

`bulk_scan(codes[], scan_type, branch, driver, note)` returns per-code results:

```json
{ "batch_id": "...", "ok": 1, "duplicates": 1, "not_found": 1, "rejected": 0,
  "results": [{ "code": "MKK-...", "serial": "MKK-...", "result": "ok", "status": "RECEIVED_AT_HUB" }] }
```

Result codes: `ok`, `duplicate`, `not_found`, `wrong_status`, `wrong_driver`, `error`.
Supported operations and their status rules:

| Scan type | Allowed shipment status | Status effect |
|---|---|---|
| `receive_at_hub` | `PICKED_UP`, `RETURN_TO_HUB` | `PICKED_UP → RECEIVED_AT_HUB` |
| `sorting` | `RECEIVED_AT_HUB` | `→ SORTING` |
| `load_to_driver` | `ASSIGNED_TO_DRIVER` (and current driver match if provided) | none |
| `return_receive` | `RETURN_TO_HUB` | none |
| `return_to_merchant` | `RETURN_TO_HUB` | `→ RETURN_TO_MERCHANT` |

Parcel serials (`...-P01`) are normalised to the shipment serial. Each row is processed in its own exception block, so one bad code never aborts the batch.

UI: `/scan/bulk` — paste up to 500 barcodes, choose the operation, get live counters and a per-code table.

### 4. Manifest closing
`close_manifest(manifest)` stores `status = 'closed'`, `closed_at/by`, and the totals `total_shipments`, `delivered_count`, `failed_count`; it frees the driver when no current assignments remain. Double close is rejected. `/dispatch` lists manifests with totals and a close button.

## Files

**Database**
- `supabase/migrations/0005_returns_ops.sql` (new)
- `supabase/tests/0005_returns_tests.sql` (new)
- `supabase/tests/run.sh` (applies 0005 and runs the new suite)

**Application**
- `src/app/(app)/returns/page.tsx` — list + status counters
- `src/app/(app)/returns/[id]/page.tsx` — details, timeline, actions
- `src/app/(app)/returns/[id]/ReturnActions.tsx` — receive / inspect / complete / cancel
- `src/app/(app)/returns/actions.ts` — server actions
- `src/app/(app)/scan/bulk/page.tsx` + `BulkScanForm.tsx` — bulk scanning UI
- `src/app/(app)/scan/actions.ts` — `bulkScan`
- `src/app/(app)/shipments/[id]/ReassignForm.tsx`, `ReturnPanel.tsx` — shipment-level actions
- `src/app/(app)/shipments/[id]/actions.ts` — `reassignShipment`
- `src/app/(app)/dispatch/page.tsx`, `actions.ts` — manifest close + inline reassignment
- `src/app/(app)/layout.tsx` — navigation entries
- `src/lib/i18n.ts` — AR/EN keys

## Verification

```
./supabase/tests/run.sh        # 15 finance + 5 phase-4 scenarios
npx tsc --noEmit               # clean
npm run build                  # 24 routes
```

Phase-4 test results:

```
PASS 1: return RET-2026-000001 created, duplicate blocked
PASS 2: return completed, 10 AED return fee posted, double completion blocked
PASS 3: reassignment to covered driver, history + audit kept, coverage enforced
PASS 4: bulk scan ok/duplicate/not_found/wrong_status all correct
PASS 5: manifest closed with totals, double close blocked
ALL PHASE 4 TESTS PASSED
```

## Deployment

1. Apply `0005_returns_ops.sql` after `0004_finance_cod.sql` (Supabase SQL editor or `supabase db push`).
2. No data backfill is required. Existing `shipment_scans` rows keep `scan_type = null` and are ignored by bulk operations.
3. Permissions are seeded automatically for owner/super_admin and the operations roles.
4. Verify with `select * from returns limit 1;` and by scanning two known serials on `/scan/bulk`.

## Known limitations / next phase

- Returns have no line items yet (parcel-level condition is a single header condition). Add `return_items` when partial returns are required.
- `load_to_driver` does not create the assignment; it validates the existing one. Assignment stays in `/dispatch`.
- Manifest printing is still browser print; a dedicated manifest PDF is part of Phase 5.
- No RLS tests yet for returns (Phase 9 pgTAP).
