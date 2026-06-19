# Budget Home V3 — محاكاة Backend/OTP قبل Firebase

## الفكرة
هذه نسخة تطوير محلية لتجربة منطق المنتج قبل إنشاء Firebase:

- الدخول برقم الموبايل.
- كود OTP تجريبي برسالة "راجع واتساب".
- دعوة أفراد العائلة عبر واتساب.
- تحديد صلاحيات كل عضو قبل الدعوة.
- الاحتفاظ بالصلاحيات عند انضمام العضو بنفس رقم الموبايل.
- الشات المالي يرد على التقارير ويؤكد الرسائل الصوتية قبل التسجيل.

## مهم
هذه ليست مزامنة حقيقية بين أجهزة مختلفة بعد. المزامنة الحقيقية تحتاج Firebase Auth + Firestore لاحقًا.

## التشغيل

```powershell
flutter clean
flutter pub get
flutter run -d e33a21f0
```

لو ظهر خطأ Android v1 embedding:

```powershell
$backup="android_old_"+(Get-Date -Format "yyyyMMdd_HHmmss"); Rename-Item .\android $backup -ErrorAction SilentlyContinue; flutter create --platforms=android .; flutter clean; flutter pub get; flutter run -d e33a21f0
```

لو ظهر خطأ مساحة:
فضّي 10-15 جيجا من C ثم أعد التشغيل.
