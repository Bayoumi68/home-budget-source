# Budget Home — AI Assistant Upgrade Notes

## تمت إضافته في هذه النسخة

- إدخال مصاريف ودخل بالكتابة أو الصوت باللغة العربية.
- Parser محلي بدون إنترنت يفهم أمثلة مثل:
  - دفعت 250 سوبر ماركت
  - بنزين 300 جنيه
  - دخل 12000 مرتب
  - دكتور 500 جنيه
- صلاحيات أعضاء محلية:
  - تسجيل المصاريف
  - عرض التقارير
  - إدارة الميزانيات
  - إدارة الأعضاء
- حد شهري لكل عضو، مع منع تسجيل المصروف عند تجاوز الحد.
- حفظ جلسة المستخدم والمجموعة، بدل الرجوع لشاشة الدخول كل مرة.
- شاشة أعضاء أقوى: عرض الصلاحيات، الحد الشهري، الصرف الحالي، وتعديل العضو من قائمة.
- شاشة إعدادات أقوى: كود الدعوة، حدود ميزانية لكل تصنيف، ونسب الصرف.
- إضافة تصريح الميكروفون في AndroidManifest.
- تفعيل OnBackInvokedCallback في AndroidManifest.
- تحسين رسالة الإدخال وإضافة أمثلة سريعة للمصاريف.

## ملاحظات مهمة

- التطبيق ما زال Local Prototype باستخدام SharedPreferences، وليس نظامًا سحابيًا حقيقيًا بين عدة أجهزة.
- كود الدعوة يعمل داخل نفس بيانات الجهاز الحالية، وليس سيرفر حقيقي حتى الآن.
- المرحلة القادمة المنطقية: Firebase/Supabase للمزامنة الحقيقية بين أفراد الأسرة، ثم اشتراكات Google Play وإعلانات.

## أوامر التشغيل

```powershell
cd "C:\Users\pc\Desktop\2026\karkar_iq\budget_home"
flutter clean
flutter pub get
flutter run -d e33a21f0
```


## V3.5 — Accounting Engine Fix

- Fixed monthly budget calculations to count current-month expenses only.
- Added category normalization utility for Arabic variants: ايجار/إيجار/الإيجار.
- Improved custom category matching so categories like “مصروف محمد” can match “دفعت 100 لمحمد”.
- Updated chat reports to use the same category/budget engine as Settings.
- Updated Analytics labels to make the current-month scope explicit.


## V4.3 Invite + Accounting Matching Fix
- Replaced placeholder Google Play invitation link with Firebase Hosting web link.
- WhatsApp invitations now include the real web app link and invite code.
- Improved Arabic category matching for attached prefixes/suffixes such as لمحمد and مصروفه.
- Custom category budgets such as محمد / مصروف محمد now match transaction notes.
- Added settings refresh action to force budget recalculation from Firestore.


## V4.6 — Visible report/accounting fix
- عرض رقم النسخة داخل شاشة الشات.
- إصلاح فهم جملة "تقرير كده" حتى لا يتم اعتبار "كده" اسم عضو.
- رسالة تأكيد تسجيل المصروف تعرض عدد العمليات المحفوظة وإجمالي مصروفات الشهر.


## V4.7
- Force session-version reset.
- Firestore diagnostics on app open.
- Separate family invite link and public trial link.
- Visible accounting save confirmation.

## V5.0
- APK-first invite/deeplink handling.
- Android allowBackup disabled to avoid restored old sessions.
- Voice Arabic locale selection improved.
- Share app button added to chat for all members.
