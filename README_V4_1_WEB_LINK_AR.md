# Budget Home V4.1 - Web Link + Android Test

هذه النسخة مهيأة للتجربة العائلية المجانية عبر Firebase Hosting.

## الفكرة

- Android يعمل كتطبيق عادي.
- iPhone/Android/PC يفتحون نفس التطبيق من رابط Web واحد.
- كل عائلة تنشئ كود دعوة خاص بها.
- البيانات التجريبية تتزامن عبر Firestore.

## أوامر الربط والبناء

```powershell
cd "C:\Users\pc\Desktop\2026\badgget\budget_home_source_v4_1_web_link"

$env:Path += ";$env:LOCALAPPDATA\Pub\Cache\bin"

flutterfire configure --project=budget-home-family-test --platforms=android,web --android-package-name=com.example.budget_home

flutter clean
flutter pub get
flutter build web --release
firebase.cmd deploy --only hosting
```

## الرابط

بعد deploy سيظهر رابط شبيه بـ:

```text
https://budget-home-family-test.web.app
```

أرسله لأي شخص. كل شخص يستطيع إنشاء عائلته أو الانضمام لعائلة بكود الدعوة.

## مهم

Firestore في test mode مناسب للتجربة فقط، وليس للإطلاق العام.
