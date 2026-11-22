# MAKKAH DELIVERY — PROJECT MASTER PLAN

> شركة مكة للتوصيل · نظام إدارة توصيل داخل الإمارات · AED · Asia/Dubai · عربي/English

## 1. الوضع الحالي

| المرحلة | النطاق | الحالة |
|---|---|---|
| 1 | الأساس: الشركة، الفروع، المستخدمون والصلاحيات، الجغرافيا، التجار، العملاء، الشحنات، الترقيم التسلسلي، الحالات، البوليصة، المسح | منفّذة في الكود المُستلَم (`0001`, `0002`) — **ملفاتها غير مرفقة في الحزمة** |
| 2 | السائقون، المركبات، التغطية، التوزيع، المانيفست، إثبات التسليم، محاولات الفشل، التتبع العام | الهجرة `0003` مُستلَمة ومُختبرة؛ **واجهاتها أُنجزت في هذه الدفعة** |
| 3 | COD، عهدة السائق، دفتر التاجر، التسويات، الفواتير، المصروفات، أقفال الفترات، التقارير المالية | **منفّذة في `0004` + واجهات المالية** |
| 4 | التقارير التشغيلية الشاملة، التصدير Excel/PDF، الإشعارات، العمل دون اتصال، النشر | متبقية |

## 2. البنية

```
Next.js 15 App Router (TypeScript, Tailwind 4)
  ├─ Server Components  → قراءة البيانات عبر Supabase (RLS)
  ├─ Server Actions     → كل الكتابة عبر RPC آمنة (SECURITY DEFINER)
  └─ Supabase Postgres  → RLS + triggers + دفتر مالي append-only
```

قاعدة صارمة: **الواجهة لا تكتب في الجداول المالية مباشرة**؛ كل حركة تمرّ بدالة قاعدة بيانات تتحقق من الصلاحية والفترة المحاسبية والتكرار.

## 3. القرارات المالية الأساسية

1. **COD ليس إيرادًا.** عند التسليم يُقيَّد كالتزام تجاه التاجر (`merchant_ledger.credit`)، ويُقيَّد النقد في عهدة السائق (`driver_ledger.cash`).
2. **دفتر مزدوج مبسّط بطرفين:** `merchant_ledger` (رصيد موجب = مستحق للتاجر) و`driver_ledger` بحسابين: `cash` (نقد الشركة بيد السائق) و`dues` (مستحق السائق).
3. **عدم قابلية التعديل:** أي تعديل على مبلغ/اتجاه/تاريخ قيد مالي مرفوض بـ trigger؛ التصحيح بقيد عكسي (`reverses_id`).
4. **التكرار:** كل دالة ترحيل تقبل `idempotency_key`، مع مفاتيح طبيعية `(shipment_id, entry_type, reference)`.
5. **VAT قابل للضبط:** يُقرأ من `companies.vat_enabled/vat_rate`، والافتراضي 0 (غير مفعّل) — لا نسبة ثابتة في الكود.
6. **فصل المهام:** منشئ التسوية لا يعتمدها إلا بدور `super_admin` (فحص دور صريح، لا صلاحية قابلة للتجاوز).
7. **أقفال الفترات:** `financial_periods.status='locked'` يمنع أي ترحيل بتاريخ داخل الفترة.

## 4. تدفّق الرسوم

```
resolve_delivery_fee(company, merchant, emirate, service, weight)
  ├─ rate_cards  (الأكثر تخصيصًا: تاجر > خدمة > إمارة، ثم priority)
  └─ merchants.delivery_fee  (عقد التاجر)
        ↓ snapshot عند إنشاء الشحنة
shipments.delivery_fee / vat_amount / fee_rate_id / fees_calculated_at
        ↓ عند التسليم (trigger على proof_of_delivery)
merchant_ledger: +COD  −delivery_fee  −vat  −extra  −cod_fee
driver_ledger:   +COD (cash)  +commission (dues)
```

## 5. خريطة الملفات الجديدة

```
supabase/migrations/0003_drivers_dispatch.sql      (المُستلَم)
supabase/migrations/0004_finance_cod.sql           (جديد — 12 جدولًا + 20 دالة + triggers + RLS)
supabase/tests/00_phase1_harness.sql               (اختباري فقط)
supabase/tests/0004_finance_tests.sql              (15 اختبارًا)
supabase/tests/run.sh

src/app/(app)/dispatch/*                           لوحة التوزيع
src/app/(app)/drivers/*                            السائقون والتغطية
src/app/driver/*                                   تطبيق السائق (PWA)
src/app/track/*                                    التتبع العام
src/app/(app)/finance/*                            المالية والتسويات
src/app/(app)/merchants/[id]/page.tsx              كشف حساب التاجر
```

## 6. المخاطر والقيود المعروفة

- **0001/0002 غير مرفقتين** في الحزمة؛ `0004` مكتوبة بشكل دفاعي (`add column if not exists`) وتفترض العقد الموضّح في `docs/DATABASE_SCHEMA.md`. يجب تشغيل `0004` على نسخة staging من مشروعك الحقيقي قبل الإنتاج.
- التتبع العام يتطلب رمز `tracking_token` (من الـQR) — لا يكفي رقم الشحنة وحده، وهذا مقصود لمنع التخمين.
- تطبيق السائق لا يدعم العمل دون اتصال بعد (PWA manifest موجود، Service Worker مؤجّل).
- لا إشعارات SMS/WhatsApp/Push فعلية بعد؛ الجداول جاهزة للتوسعة.
- `next_doc_no` مستخدم لأرقام STL/INV/EXP/PAY؛ تأكد من وجوده في `0001` (هو موجود في `0003`).

## 7. الخطوة التالية المقترحة

1. رفع `0001` و`0002` لتشغيل سلسلة الهجرات كاملة على staging.
2. شاشة المرتجعات واستلامها في المركز.
3. تقارير Excel/PDF (ExcelJS + طباعة المتصفح).
4. Service Worker لتطبيق السائق + طابور مزامنة idempotent.
5. ربط مزوّد خرائط عبر طبقة تجريد.
