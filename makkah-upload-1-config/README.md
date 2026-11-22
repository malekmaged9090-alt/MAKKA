# MAKKAH DELIVERY

نظام إدارة توصيل داخل الإمارات (Next.js 15 + Supabase/Postgres).

## التشغيل (محلياً أو على السحابة)

الدليل المفصّل خطوة بخطوة للسحابة (Supabase + GitHub + Netlify): **`DEPLOY_AR.md`**.

1. `npm install`
2. في Supabase SQL Editor نفّذ بالترتيب: `supabase/setup/01_ALL_IN_ONE.sql` (وقبله `00_RESET_public_schema.sql` فقط إن كانت القاعدة فيها بقايا ولا بيانات مهمة). الملف يعمل كمعاملة واحدة: إن فشل شيء لا يُطبَّق شيء.
3. Authentication ← Users ← Add user (فعّل Auto Confirm) ثم نفّذ `supabase/setup/02_bootstrap_admin.sql` بعد وضع بريدك فيه، وتأكد من ظهور `Owner ready`.
4. `supabase/verify_production.sql`: كل استعلام فيه يجب أن يرجع **صفر صفوف**.
5. انسخ `.env.example` إلى `.env.local` واملأ `NEXT_PUBLIC_SUPABASE_URL` و`NEXT_PUBLIC_SUPABASE_ANON_KEY` و`NEXT_PUBLIC_SITE_URL`، ثم `npm run dev`.

> **أمان:** المرجع الوحيد هو الهجرات `0001`–`0009` (وملف 01_ALL_IN_ONE مولَّد منها بـ `npm run build:setup`). لا تخلطها بنسخ قديمة من `0001/0002`: النسخ البديلة القديمة بلا RLS. لا تضع مفتاح `service_role` في التطبيق أو في متغيرات Netlify أبداً.

## ما بداخل التطبيق
شحنات (إنشاء، **استيراد Excel**، طباعة بوليصة وباركود، تتبع) · توزيع وتطبيق سائق · مسح باركود · مرتجعات · مالية وتسويات · تقارير · إشعارات · **المناطق (تغطية + استيراد Excel)** · **العملاء** · التجار والسائقون · **المستخدمون والأدوار** · القائمة الجانبية تظهر كل مستخدم ما يملك صلاحيته فقط.

## المسارات

| المسار | الوصف |
|---|---|
| `/` | لوحة التحكم |
| `/shipments`, `/shipments/new`, `/shipments/[id]` | الشحنات ودورة الحالة |
| `/shipments/[id]/waybill` | بوليصة 100×150 أو A4 مع Code128 وQR |
| `/dispatch` | التوزيع اليدوي/الجماعي/التلقائي والمانيفست |
| `/drivers`, `/drivers/new` | السائقون والتغطية والمركبات |
| `/driver`, `/driver/[id]` | تطبيق السائق (PWA) |
| `/track`, `/track/[number]?t=token` | التتبع العام |
| `/merchants`, `/merchants/[id]` | التجار وكشف الحساب |
| `/finance` | COD والعهد والمطابقة |
| `/finance/settlements`, `/[id]` | التسويات ومستندها القابل للطباعة |
| `/scan` | مسح الباركود |
| `/scan/bulk` | المسح الجماعي مع نتائج لكل باركود ومنع التكرار |
| `/returns`, `/returns/[id]` | دورة المرتجعات والاستلام والفحص والإعادة للتاجر |
| `/reports` | 18 تقريرًا حيًا مع فلاتر التاريخ والحالة وتصدير CSV |
| `/notifications` | إشعارات النظام وOutbox القنوات الخارجية |

## الاختبارات

```bash
npm install
npm test             # = test:db + test:unit؛ قاعدة PostgreSQL حقيقية داخل العملية (PGlite)؛ بلا Docker ولا sudo
npm run typecheck
npm run build
```

`test:db` يطبّق كل الهجرات على قاعدة نظيفة ويشغّل 6 ملفات (96 اختباراً): **الأمان وRLS** (15)، **التوزيع والسائق والتتبع** (24)، **المحاسبة والمرتجعات والتقارير** (22)، **إدارة المستخدمين** (14)، **الاستيراد والعملاء والمناطق تحت RLS** (7)، **ملفات الإعداد الفعلية للسحابة** (7). و`test:unit` يختبر منطق استيراد Excel على ملفات xlsx حقيقية.

## التوثيق

- `PROJECT_MASTER_PLAN.md`
- `docs/DATABASE_SCHEMA.md`
- `docs/API_DOCUMENTATION.md`
- `docs/USER_PERMISSIONS.md`
- `docs/DEVELOPMENT_ROADMAP.md`
- `docs/TESTING_PLAN.md`
- `docs/PHASE_2_3_REPORT.md`
- `docs/PHASE_4_REPORT.md`
- `docs/FINAL_RELEASE_REPORT.md`
- `TODO.md`
