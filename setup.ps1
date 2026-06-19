# Budget Home — Setup Script
# شغّل هذا السكريبت في مجلد budget_home
# Pascal PowerShell (انقر يمين → Run with PowerShell)

Write-Host "==============================" -ForegroundColor Green
Write-Host " Budget Home - Setup " -ForegroundColor Green
Write-Host "==============================" -ForegroundColor Green
Write-Host ""

# ─── 1. التأكد من وجود Flutter ───
Write-Host "[1/4] التحقق من Flutter..." -ForegroundColor Cyan
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    Write-Host "❌ Flutter غير موجود!" -ForegroundColor Red
    Write-Host "حمّله من: https://docs.flutter.dev/get-started/install/windows" -ForegroundColor Yellow
    Write-Host "بعد التثبيت، شغّل السكريبت مرة أخرى" -ForegroundColor Yellow
    Read-Host "اضغط Enter للخروج"
    exit 1
}
Write-Host "✅ Flutter موجود: $(flutter --version | Select-Object -First 1)" -ForegroundColor Green
Write-Host ""

# ─── 2. إنشاء ملفات Android/iOS ───
Write-Host "[2/4] إنشاء ملفات المنصات..." -ForegroundColor Cyan
if (-not (Test-Path "android\build.gradle")) {
    flutter create --project-name budget_home .
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ فشل إنشاء المشروع" -ForegroundColor Red
        Read-Host "اضغط Enter للخروج"
        exit 1
    }
    Write-Host "✅ تم إنشاء ملفات Android/iOS" -ForegroundColor Green
} else {
    Write-Host "⏭ الملفات موجودة مسبقاً" -ForegroundColor Yellow
}
Write-Host ""

# ─── 3. تحميل الحزم ───
Write-Host "[3/4] تحميل الحزم (flutter pub get)..." -ForegroundColor Cyan
flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ فشل تحميل الحزم" -ForegroundColor Red
    Read-Host "اضغط Enter للخروج"
    exit 1
}
Write-Host "✅ تم تحميل جميع الحزم" -ForegroundColor Green
Write-Host ""

# ─── 4. تعليمات Firebase ───
Write-Host "[4/4] إعداد Firebase (يدوي)" -ForegroundColor Cyan
Write-Host ""
Write-Host "┌─────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "│ خطوة مهمة: إعداد Firebase                               │" -ForegroundColor Yellow
Write-Host "├─────────────────────────────────────────────────────────┤" -ForegroundColor Yellow
Write-Host "│ 1. افتح https://console.firebase.google.com            │" -ForegroundColor White
Write-Host "│ 2. أنشئ مشروع جديد                                     │" -ForegroundColor White
Write-Host "│ 3. أضف تطبيق Android (com.budget.home)                 │" -ForegroundColor White
Write-Host "│ 4. حمّل google-services.json                           │" -ForegroundColor White
Write-Host "│ 5. ضع الملف في: android/app/google-services.json      │" -ForegroundColor White
Write-Host "│ 6. في Terminal شغّل:                                    │" -ForegroundColor White
Write-Host "│    dart run firebase_core:configure                    │" -ForegroundColor White
Write-Host "└─────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""

# ─── 5. تشغيل التطبيق ───
Write-Host "==============================" -ForegroundColor Green
Write-Host "✅ التثبيت اكتمل!" -ForegroundColor Green
Write-Host "==============================" -ForegroundColor Green
Write-Host ""
Write-Host "لتشغيل التطبيق على جهازك:" -ForegroundColor Cyan
Write-Host "  1. وصّل الموبايل بالكمبيوتر (USB Debugging مفعّل)" -ForegroundColor White
Write-Host "  2. أو افتح Android Emulator" -ForegroundColor White
Write-Host "  3. شغّل الأمر:" -ForegroundColor White
Write-Host "     flutter run" -ForegroundColor Magenta
Write-Host ""

$runNow = Read-Host "هل تريد تشغيل التطبيق الآن؟ (Y/N)"
if ($runNow -eq "Y" -or $runNow -eq "y") {
    Write-Host "جاري تشغيل التطبيق..." -ForegroundColor Cyan
    flutter run
}

Read-Host "اضغط Enter للخروج"
