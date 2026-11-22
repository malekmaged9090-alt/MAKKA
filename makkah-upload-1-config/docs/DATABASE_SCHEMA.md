# DATABASE SCHEMA — 0004 Finance & COD

كل المبالغ `numeric(12,2)` بالدرهم. كل الجداول تحمل `company_id` عدا بنود التسوية والفواتير التابعة.

## 1. الجداول الجديدة

### financial_periods
| العمود | النوع | ملاحظات |
|---|---|---|
| id | uuid PK | |
| company_id | uuid FK companies | |
| period_start / period_end | date | `end >= start` |
| status | text | `open` / `locked` |
| locked_by / locked_at | uuid / timestamptz | |

قيد فريد `(company_id, period_start, period_end)`.

### rate_cards
بطاقات أسعار هرمية: `merchant_id`, `emirate_id`, `service_type` كلها اختيارية؛ الأكثر تخصيصًا يفوز.
`base_fee`, `per_kg_fee`, `return_fee`, `cod_fee_percent`, `priority`, `is_active`.

### cod_transactions
سجل تحصيل COD لكل شحنة (صف واحد لكل شحنة — `unique(shipment_id)`).
`amount`, `handed_amount` (يُحدَّث فقط عبر التوريد)، `collected_method`, `driver_id`, `merchant_id`, `occurred_at`.

### driver_ledger (append-only)
| العمود | القيم |
|---|---|
| account | `cash` (نقد الشركة بيد السائق) / `dues` (مستحق السائق) |
| entry_type | cod_collection, cash_handover, commission, advance, expense_reimbursement, deduction, cash_shortage, cash_overage, payout, adjustment, reversal |
| amount | > 0 |
| direction | +1 / −1 |
| shipment_id / session_id / reference | ربط |
| idempotency_key | فريد لكل شركة |
| reverses_id | فريد، للقيد العكسي |

فهرس فريد `(shipment_id, entry_type, reference)` يمنع تكرار قيد نفس الشحنة.

### driver_cash_sessions
`business_date`, `status open/closed`, `opening_balance`, `collected_cod`, `handed_over`, `expenses_paid`,
`expected_cash`, `counted_cash`, `difference`, `closed_by/at`. فريد `(company, driver, business_date)`.

### merchant_ledger (append-only)
نفس بنية الاتجاه؛ `direction=+1` = دائن للتاجر (مستحق له)، `−1` = مدين.
الأنواع: cod_collected, delivery_fee, extra_fee, vat_on_fee, cod_fee, return_fee, extra_attempt_fee, settlement_payment, adjustment, reversal.
`settlement_id` يُملأ عند إنشاء التسوية لقفل القيد ومنع إدراجه في تسوية ثانية.

### merchant_settlements
`settlement_no` (STL-YYYY-NNNNNN), `merchant_id`, `period_start/end`, تفصيل المبالغ, `net_payable` (يمكن أن يكون سالبًا),
`status draft/under_review/approved/paid/cancelled`, `created_by`, `approved_by/at`, `paid_at`, `idempotency_key`.

### settlement_lines
`settlement_id`, `ledger_id unique`, `shipment_id`, `entry_type`, `amount` (موقّع).

### invoices / invoice_lines
`invoice_no` (INV-YYYY-NNNNNN), `invoice_type delivery/cod/other`, `subtotal`, `vat_amount`, `total`,
`status draft/issued/paid/void`, `settlement_id`.

### expenses
`expense_no` (EXP-…), `category`, `amount`, `vat_amount`, `paid_from bank/cash/driver_cash`,
`status draft/approved/paid/rejected`. الدفع من `driver_cash` ينشئ قيدًا سالبًا في عهدة السائق.

### payments
`party_type merchant/driver/supplier`, `direction out/in`, `amount`, `method`, `settlement_id`, `expense_id`, `idempotency_key`.

## 2. الأعمدة المضافة دفاعيًا

```sql
companies: vat_enabled, vat_rate, trn
merchants: delivery_fee, return_fee, extra_attempt_fee, cod_fee_percent
shipments: delivery_fee, extra_fee, vat_amount, fee_rate_id, fees_calculated_at
drivers:   commission_per_delivery
```

## 3. العلاقات

```
shipments 1─1 cod_transactions
shipments 1─* merchant_ledger
shipments 1─* driver_ledger
drivers   1─* driver_ledger / driver_cash_sessions
merchants 1─* merchant_ledger / merchant_settlements / invoices
merchant_settlements 1─* settlement_lines 1─1 merchant_ledger
invoices 1─* invoice_lines
```

## 4. Triggers

| Trigger | الجدول | الأثر |
|---|---|---|
| trg_pod_finance | proof_of_delivery AFTER INSERT | ترحيل COD + الرسوم + العمولة |
| trg_return_fee | shipment_status_events AFTER INSERT | رسم الإرجاع عند `RETURN_TO_MERCHANT` (مرة واحدة) |
| trg_attempt_fee | failed_delivery_attempts AFTER INSERT | رسم محاولة إضافية بدءًا من المحاولة الثانية |
| trg_shipment_fees | shipments BEFORE INSERT | تثبيت سعر التوصيل وVAT |
| trg_*_ro / trg_*_del | الدفاتر | منع التعديل/الحذف المالي |

## 5. RLS

قراءة فقط للمستخدمين المصرح لهم:
- `finance.read` → كل الشركة.
- السائق → `driver_ledger` و`cod_transactions` و`driver_cash_sessions` الخاصة به فقط.
- التاجر (`shipments.read_own`) → `merchant_ledger` وتسوياته وفواتيره فقط.
- الكتابة ممنوعة من الجداول مباشرة؛ تتم عبر دوال `security definer` فقط.

## 6. المرحلة 4 (0005)

### returns
| العمود | النوع | ملاحظات |
|---|---|---|
| id | uuid PK | |
| company_id, return_no | uuid, text | `RET-YYYY-NNNNNN`، فريد للشركة |
| shipment_id | uuid | فريد جزئيًا حيث `status <> 'cancelled'` |
| merchant_id, customer_id | uuid | لقطة عن الشحنة |
| return_type | text | customer_return / failed_delivery / refused / wrong_address / damaged / exchange |
| reason_code, reason_note | text | السبب إجباري |
| status | text | requested / received_at_hub / inspected / returned_to_merchant / cancelled |
| branch_id | uuid | فرع الاستلام |
| requested_by/at, received_by/at, inspected_by/at, completed_by/at, cancelled_by/at | | طوابع زمنية ومستخدمون |
| condition | text | good / damaged / missing_items |
| inspection_note, cancel_reason | text | |

### shipment_scans (موسّع)
الأعمدة الجديدة: `company_id`, `scan_type`, `batch_id`, `branch_id`, `driver_id`, `note`, `device`.
فهرس فريد `(shipment_id, scan_type, batch_id)` يمنع تكرار نفس المسح داخل الدفعة.

### dispatch_manifests (موسّع)
`status` (open/closed), `closed_at`, `closed_by`, `total_shipments`, `delivered_count`, `failed_count`.

### الصلاحيات الجديدة
`returns.read`, `returns.manage`, `returns.complete`, `scans.bulk`.

### دوال
`create_return`, `receive_return`, `inspect_return`, `complete_return`, `cancel_return`,
`reassign_shipment_ext`, `bulk_scan`, `close_manifest`.
