# USER PERMISSIONS

## 1. الأدوار

`super_admin`, `owner`, `ops_manager`, `branch_manager`, `dispatcher`, `customer_service`,
`accountant`, `cashier`, `warehouse`, `driver`, `merchant_admin`, `merchant_employee`, `auditor`.

## 2. مصفوفة صلاحيات المالية (0004)

| الصلاحية | super_admin | owner | accountant | cashier | ops_manager | dispatcher | auditor | driver | merchant_admin |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| finance.read | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔* | ✔* |
| finance.manage | ✔ | ✔ | ✔ | | | | | | |
| settlements.approve | ✔ | ✔ | ✔ | | | | | | |
| settlements.pay | ✔ | ✔ | ✔ | ✔ | | | | | |
| settlements.override_sod | ✔ | | | | | | | | |
| cash.manage | ✔ | ✔ | ✔ | ✔ | ✔ | | | | |
| cash.close | ✔ | ✔ | ✔ | ✔ | ✔ | | | | |
| expenses.manage | ✔ | ✔ | ✔ | | | | | | |
| invoices.manage | ✔ | ✔ | ✔ | | | | | | |
| rates.manage | ✔ | ✔ | ✔ | | | | | | |

\* قراءة مقيدة بـRLS: السائق يرى حركاته فقط، والتاجر يرى حركاته فقط.

> `settlements.override_sod` ممنوحة لـ`super_admin` فقط. فحص فصل المهام في `approve_merchant_settlement` يعتمد على **الدور الفعلي** لا على `has_permission`، لأن بعض التثبيتات تمنح owner/super_admin تجاوزًا عامًا.

## 3. نطاق الرؤية (RLS)

| الجدول | من يرى |
|---|---|
| cod_transactions | `finance.read`، أو السائق صاحب الحركة، أو التاجر صاحب الشحنة |
| driver_ledger | `finance.read`، أو السائق نفسه |
| driver_cash_sessions | `finance.read`، أو السائق نفسه |
| merchant_ledger | `finance.read`، أو التاجر نفسه |
| merchant_settlements / invoices | `finance.read`، أو التاجر نفسه |
| expenses / payments / financial_periods | `finance.read` فقط |

## 4. منع الكتابة المباشرة

لا توجد سياسات INSERT/UPDATE/DELETE على الجداول المالية. كل كتابة عبر دوال `security definer` تتحقق من:
1. الصلاحية.
2. نطاق الشركة.
3. الفترة المحاسبية غير مقفلة.
4. عدم تكرار العملية (idempotency + مفاتيح طبيعية).
5. قواعد العمل (رصيد العهدة، فصل المهام، حالة التسوية).

## 5. واجهة المستخدم

- القائمة الجانبية تعرض كل الوحدات، لكن الصلاحية الفعلية تُفرض في قاعدة البيانات؛ أي محاولة غير مصرح بها ترجع رسالة `permission ... required`.
- صفحة `/driver` تتطلب ربط `drivers.user_id` بحساب الدخول؛ إن لم يوجد يعرض «حسابك غير مرتبط بسائق».
- `/track` عامة ولا تعرض هاتفًا كاملًا أو بيانات مالية؛ تتطلب `tracking_number + tracking_token`.
