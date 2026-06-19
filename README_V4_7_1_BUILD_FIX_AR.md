# Budget Home V4.7.1 - إصلاح بناء الويب

تم إصلاح خطأ dart2js الناتج عن تكرار كلمة داخل `_reportStopWords` في `lib/services/ai_service.dart`.

رقم النسخة داخل التطبيق:
`0.4.7.1-build-fix-firestore-visible`

أوامر النشر:

```powershell
cd "C:\Users\pc\Desktop\2026\badgget\budget_home_source_v4_7_1_build_fix_firestore_visible"

$env:Path += ";$env:LOCALAPPDATA\Pub\Cache\bin"

flutterfire configure --project=budget-home-family-test --platforms=android,web --android-package-name=com.example.budget_home

flutter clean
flutter pub get
flutter build web --release --pwa-strategy=none

firebase.cmd deploy --only hosting
```

بعد النشر افتح:
`https://budget-home-family-test.web.app/?reset=1&v=471`

افتح Firestore ثم تأكد من ظهور collection باسم `diagnostics` بمجرد فتح التطبيق.
