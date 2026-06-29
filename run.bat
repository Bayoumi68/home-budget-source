@echo off
cd /d "%~dp0"
echo ==============================
echo Home Budget - تشغيل على الموبايل
echo ==============================
echo.

:: 1. تهيئة المشروع لو ناقص
if not exist android\build.gradle.kts (
    echo [1/3] تهيئة المشروع...
    call flutter create --project-name budget_home .
    if errorlevel 1 ( echo خطأ: فشل إنشاء المشروع & pause & exit /b )
    echo تم
) else (
    echo [1/3] المشروع جاهز
)

:: 2. تحميل الحزم
echo [2/3] تحميل الحزم...
call flutter pub get
if errorlevel 1 ( echo خطأ: فشل تحميل الحزم & pause & exit /b )
echo تم

:: 3. اكتشاف الموبايل عبر adb (وليس تشغيله على الكمبيوتر)
set "ADB=%USERPROFILE%\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" set "ADB=adb"

set "SERIAL="
for /f "usebackq skip=1 tokens=1,2" %%a in (`"%ADB%" devices 2^>nul`) do (
    if "%%b"=="device" if not defined SERIAL set "SERIAL=%%a"
)

if not defined SERIAL (
    echo.
    echo [!] لم يتم العثور على موبايل متصل، ولن يتم التشغيل على الكمبيوتر.
    echo     لتشغيل التطبيق على هاتفك، فعّل أولًا:
    echo       1^) الإعدادات ^> حول الهاتف ^> اضغط "رقم الإصدار/Build number" 7 مرات
    echo       2^) الإعدادات ^> خيارات المطور ^> فعّل "تصحيح USB / USB debugging"
    echo       3^) وصّل الكابل واضغط "السماح/Allow" على الهاتف
    echo.
    echo     ثم شغّل هذا الملف مرة أخرى.
    echo.
    pause
    exit /b
)

:: 4. تشغيل التطبيق على الموبايل المكتشف
echo [3/3] تشغيل التطبيق على الموبايل (%SERIAL%)...
echo.
call flutter run -d %SERIAL%

pause
