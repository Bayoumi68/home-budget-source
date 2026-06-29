# Home Budget — Setup Script
# شغّل هذا السكريبت في مجلد المشروع
# انقر يمين → Run with PowerShell

Write-Host "==============================" -ForegroundColor Green
Write-Host " Home Budget - Setup " -ForegroundColor Green
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
if (-not (Test-Path "android\build.gradle.kts")) {
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
Write-Host "[4/4] إعداد Firebase" -ForegroundColor Cyan
Write-Host ""
Write-Host "المشروع موصول بمشروع Firebase: budget-home-bayoumi" -ForegroundColor White
Write-Host "ملف الويب (lib/firebase_options.dart) محفوظ في git، لكن" -ForegroundColor White
Write-Host "android/app/google-services.json غير محفوظ (مستبعد في .gitignore)." -ForegroundColor White
Write-Host "لإعادة توليده — أو لربط مشروع Firebase خاص بك — شغّل:" -ForegroundColor White
Write-Host "   dart pub global activate flutterfire_cli" -ForegroundColor Magenta
Write-Host "   firebase login" -ForegroundColor Magenta
Write-Host "   flutterfire configure --project=budget-home-bayoumi" -ForegroundColor Magenta
Write-Host ""
Write-Host "ثم في Firebase Console فعّل طرق الدخول: Google و Email/Password." -ForegroundColor White
Write-Host "(الحزمة الافتراضية للأندرويد: com.example.budget_home)" -ForegroundColor DarkGray
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

$runNow = Read-Host "هل تريد تشغيل التطبيق على موبايلك الآن؟ (Y/N)"
if ($runNow -eq "Y" -or $runNow -eq "y") {
    # حدد adb لاكتشاف الموبايل (وعدم التشغيل على الكمبيوتر)
    $adb = "$env:USERPROFILE\Android\Sdk\platform-tools\adb.exe"
    if (-not (Test-Path $adb)) { $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" }
    if (-not (Test-Path $adb)) { $adb = "adb" }

    $serial = $null
    try {
        foreach ($line in (& $adb devices 2>$null)) {
            if ($line -match '^(\S+)\s+device$') { $serial = $Matches[1]; break }
        }
    } catch {}

    if ($serial) {
        Write-Host "جاري التشغيل على الموبايل ($serial)..." -ForegroundColor Cyan
        flutter run -d $serial
    } else {
        Write-Host ""
        Write-Host "[!] لم يتم العثور على موبايل متصل، ولن يتم التشغيل على الكمبيوتر." -ForegroundColor Yellow
        Write-Host "    فعّل أولًا: الإعدادات > حول الهاتف > اضغط 'رقم الإصدار' 7 مرات،" -ForegroundColor White
        Write-Host "    ثم خيارات المطور > USB debugging، ووصّل الكابل واضغط 'السماح'." -ForegroundColor White
    }
}

Read-Host "اضغط Enter للخروج"
