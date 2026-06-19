@echo off
cd /d "%~dp0"
echo ==============================
echo Budget Home - تشغيل سريع
echo ==============================
echo.

:: 1. إنشاء ملفات Android/iOS
if not exist android\build.gradle (
    echo [1/3] تهيئة المشروع...
    call flutter create --project-name budget_home .
    if errorlevel 1 (
        echo خطأ: فشل إنشاء المشروع
        echo تأكد من تثبيت Flutter: https://docs.flutter.dev/get-started/install/windows
        pause
        exit /b
    )
    echo تم
) else (
    echo [1/3] المشروع جاهز
)

:: 2. تحميل الحزم
echo [2/3] تحميل الحزم...
call flutter pub get
if errorlevel 1 ( echo خطأ: فشل تحميل الحزم & pause & exit /b )
echo تم

:: 3. تشغيل التطبيق
echo.
echo [3/3] تشغيل التطبيق على الجهاز المتصل...
echo.
call flutter run

pause
