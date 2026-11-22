# API — Finance RPCs (0004)

كل الدوال `SECURITY DEFINER` وتتحقق من `current_company_id()` والصلاحية. تُستدعى من التطبيق عبر `supabase.rpc(...)`، ومن الخارج عبر PostgREST بنفس الأسماء.

## 1. العهدة النقدية

### record_cash_handover
```ts
rpc("record_cash_handover", {
  p_driver: uuid, p_amount: number, p_reference?: string,
  p_note?: string, p_idempotency_key?: uuid
}) → uuid
```
- الصلاحية: `cash.manage` أو `finance.manage`.
- يرفض المبلغ ≤ 0، والسائق غير التابع للشركة، والمبلغ أكبر من رصيد العهدة.
- يوزّع المبلغ على صفوف COD بالأقدم أولًا (`handed_amount`).
- إعادة الإرسال بنفس `idempotency_key` تُرجع نفس المعرّف دون ترحيل.

### close_driver_cash_session
```ts
rpc("close_driver_cash_session", { p_session: uuid, p_counted: number, p_note?: string }) → number
```
- الصلاحية: `cash.close` أو `finance.manage`.
- `expected = opening_balance + حركات الجلسة`، والفرق = المعدود − المتوقع.
- فرق غير صفري يتطلب ملاحظة، ويُرحَّل كـ `cash_shortage` أو `cash_overage`.
- إغلاق مكرر مرفوض.

### pay_driver_dues
```ts
rpc("pay_driver_dues", { p_driver, p_amount, p_method?, p_reference?, p_idempotency_key? }) → uuid
```
- الصلاحية: `finance.manage`؛ يمنع تجاوز رصيد `dues`.

## 2. التسويات

### create_merchant_settlement
```ts
rpc("create_merchant_settlement", {
  p_merchant: uuid, p_from: date, p_to: date, p_note?: string, p_idempotency_key?: uuid
}) → uuid
```
- الصلاحية: `finance.manage` أو `settlements.approve`.
- يأخذ كل قيود `merchant_ledger` غير المرتبطة بتسوية داخل الفترة، ينشئ `settlement_lines`، ويقفلها بـ`settlement_id`.
- يرفض الفترة المقلوبة أو عدم وجود قيود مفتوحة.
- `net_payable` = Σ(amount × direction).

### submit / approve / pay / cancel
```ts
submit_merchant_settlement(p_settlement uuid) → void
approve_merchant_settlement(p_settlement uuid) → void
pay_merchant_settlement(p_settlement, p_method?, p_reference?, p_idempotency_key?) → uuid
cancel_merchant_settlement(p_settlement, p_reason) → void
```
- `submit`: draft → under_review.
- `approve`: draft/under_review → approved، ويتطلب `settlements.approve` و**ألا يكون المعتمد هو المنشئ** (إلا بدور `super_admin`).
- `pay`: approved → paid، ينشئ `payments` وقيد `settlement_payment`؛ إن كان الصافي سالبًا يصبح الاتجاه `in` (التاجر يدفع).
- `cancel`: مسموح قبل الدفع فقط، ويفك ارتباط القيود.

### create_invoice_from_settlement
```ts
rpc("create_invoice_from_settlement", { p_settlement: uuid }) → uuid
```
- الصلاحية: `invoices.manage`. Subtotal = الرسوم + الإضافية + الإرجاع + COD fee، وVAT من التسوية.
- idempotent: تعيد الفاتورة الموجودة إن وُجدت.

## 3. المصروفات والتعديلات

```ts
record_expense(p_category, p_amount, p_description?, p_vat?, p_paid_from?,
               p_driver?, p_branch?, p_date?, p_idempotency_key?) → uuid
approve_expense(p_expense) → void
pay_expense(p_expense) → void
record_adjustment(p_party_type 'merchant'|'driver', p_party_id, p_amount,
                  p_reason, p_direction? , p_idempotency_key?) → uuid
```
- `record_expense` يرفض الترحيل داخل فترة مقفلة.
- `pay_expense` مع `paid_from='driver_cash'` يخصم من عهدة السائق.

## 4. التقارير

```ts
merchant_statement(p_merchant uuid, p_from date, p_to date) → jsonb
driver_statement(p_driver uuid, p_from date, p_to date) → jsonb
finance_overview() → jsonb
cod_reconciliation(p_date date?) → jsonb
```

`finance_overview` يعيد:
```json
{
  "date": "2026-11-20",
  "cod_collected_today": 0,
  "cod_with_drivers": 0,
  "cash_handed_today": 0,
  "merchant_payable_open": 0,
  "revenue_today": 0,
  "vat_today": 0,
  "expenses_today": 0,
  "settlements_in_progress": 0
}
```

## 5. أخطاء متوقعة

| الرسالة | السبب |
|---|---|
| `permission X required` | المستخدم لا يملك الصلاحية |
| `handover (x) exceeds the driver cash balance (y)` | توريد أكبر من العهدة |
| `a note is required when the counted cash differs by x` | فرق عهدة بلا تبرير |
| `separation of duties: the creator cannot approve this settlement` | اعتماد ذاتي |
| `settlement must be approved before payment` | دفع قبل الاعتماد |
| `accounting period is locked for YYYY-MM-DD` | ترحيل في فترة مقفلة |
| `merchant_ledger is append-only...` | محاولة تعديل قيد |

## 6. دورة حياة الشحنة (من 0003)

`change_shipment_status(p_shipment, p_to, p_reason?, p_note?, p_branch?, p_attachment?)`
تحقق انتقالًا مسموحًا + صلاحية `shipments.status` + سببًا عند الحاجة.
تطبيق السائق: `driver_accept`, `driver_out_for_delivery`, `driver_deliver`, `driver_fail`, `driver_return_to_hub`, `driver_set_status`.
التوزيع: `assign_shipments(p_driver, p_shipments[])`, `auto_dispatch(p_shipments[])`, `reassign_shipment(...)`.

## 7. المرحلة 4 — المرتجعات وإعادة الإسناد والمسح الجماعي

### المرتجعات
| الدالة | الصلاحية | الأثر |
|---|---|---|
| `create_return(p_shipment, p_reason_code, p_note?, p_type?, p_branch?)` | `returns.manage` | ينشئ مرتجعًا وينقل الشحنة إلى `RETURN_TO_HUB` |
| `receive_return(p_return, p_branch?, p_note?)` | `returns.manage` | `requested → received_at_hub` |
| `inspect_return(p_return, p_condition, p_note?)` | `returns.complete` | `received_at_hub → inspected` |
| `complete_return(p_return)` | `returns.complete` | `inspected → returned_to_merchant` + `RETURN_TO_MERCHANT` + رسم الإرجاع |
| `cancel_return(p_return, p_reason)` | `returns.manage` | إلغاء قبل الفحص |

الحالات: `requested`, `received_at_hub`, `inspected`, `returned_to_merchant`, `cancelled`.
مرتجع نشط واحد فقط لكل شحنة (فهرس فريد جزئي).

### إعادة الإسناد
`reassign_shipment_ext(p_shipment, p_driver, p_reason)`
- من `ASSIGNED_TO_DRIVER` أو `OUT_FOR_DELIVERY` أو `RESCHEDULED`.
- سبب إجباري، والسائق يجب أن يكون نشطًا ويغطي منطقة التسليم (إلا بـ`dispatch.override_area`).
- يُغلق الإسناد السابق ويُنشئ مانيفست/إسنادًا جديدًا ويكتب حدث تدقيق.

### المسح الجماعي
`bulk_scan(p_codes text[], p_scan_type, p_branch?, p_driver?, p_note?)`

```json
{
  "batch_id": "uuid",
  "scan_type": "receive_at_hub",
  "ok": 2, "duplicates": 1, "not_found": 0, "rejected": 1,
  "results": [
    { "code": "MKK-2026-000001", "serial": "MKK-2026-000001", "result": "ok", "status": "RECEIVED_AT_HUB" },
    { "code": "MKK-2026-000002", "serial": "MKK-2026-000002", "result": "wrong_status", "reason": "DELIVERED" }
  ]
}
```

`p_scan_type`: `receive_at_hub`, `sorting`, `load_to_driver`, `return_receive`, `return_to_merchant`.
النتائج المحتملة: `ok`, `duplicate`, `not_found`, `wrong_status`, `wrong_driver`, `error`.
الحد الموصى به 500 باركود في الدفعة (الواجهة تقصّ عند 500).

### إغلاق المانيفست
`close_manifest(p_manifest)` — صلاحية `dispatch.assign`.
يعيد `{manifest_id,total,delivered,failed}` ويمنع الإغلاق المزدوج.

### أخطاء إضافية
| الرسالة | السبب |
|---|---|
| `an active return already exists for this shipment` | مرتجع مفتوح مسبقًا |
| `return must be inspected first (received_at_hub)` | محاولة إكمال قبل الفحص |
| `shipment status X cannot be reassigned` | حالة لا تسمح بإعادة الإسناد |
| `driver X does not cover the delivery area` | خارج التغطية |
| `manifest already closed` | إغلاق مزدوج |
