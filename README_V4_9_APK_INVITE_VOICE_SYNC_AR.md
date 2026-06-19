# Budget Home V4.9 — APK Invite + Voice + In-App Sync

## تغييرات مهمة

- رسالة دعوة العضو أصبحت توجه إلى صفحة تثبيت APK بدل فتح الويب مباشرة.
- صفحة `install.html` تعرض زر تحميل APK وزر فتح الدعوة داخل التطبيق.
- تم إضافة Deep Link بصيغة `budgethome://join?...` لملء الاسم والرقم وكود الدعوة تلقائيًا عند فتح التطبيق بعد التثبيت.
- تحسين التسجيل الصوتي: الاحتفاظ بالنتائج الجزئية وعدم انتظار `finalResult` فقط، لأن بعض أجهزة Android لا ترسل finalResult.
- تحديث تلقائي داخل الشات كل 6 ثواني لجلب رسائل/إشعارات/ميزانية العائلة أثناء فتح التطبيق.
- ظهور Snackbar عند وصول إشعار داخلي جديد من عضو آخر أثناء فتح التطبيق.

## نشر APK كرابط تثبيت

بعد بناء APK:

```powershell
flutter build apk --debug
flutter build web --release --pwa-strategy=none
Copy-Item ".\build\app\outputs\flutter-apk\app-debug.apk" ".\build\web\budget-home.apk" -Force
firebase.cmd deploy --only hosting
```

رابط APK سيصبح:

```text
https://budget-home-family-test.web.app/budget-home.apk
```

