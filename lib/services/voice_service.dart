import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class VoiceService {
  stt.SpeechToText? _speech;
  bool _initialized = false;
  String? _preferredArabicLocale;
  String? _lastError;

  bool get isAvailable => _initialized;
  bool get isListening => _speech?.isListening ?? false;
  String? get lastError => _lastError;

  Future<bool> initialize(
      {Function(String status)? onStatus,
      Function(String error)? onError}) async {
    _lastError = null;
    if (kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _initialized = false;
      _lastError =
          'الصوت داخل نسخة الويب على iPhone غير مدعوم بثبات. استخدم ميكروفون كيبورد الآيفون داخل خانة الكتابة، ثم اضغط إرسال.';
      onError?.call(_lastError!);
      return false;
    }

    if (!kIsWeb) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        _lastError = permission.isPermanentlyDenied
            ? 'إذن الميكروفون مرفوض نهائيًا. افتح إعدادات التطبيق وفعّل الميكروفون.'
            : 'لم يتم منح إذن الميكروفون للتطبيق.';
        onError?.call(_lastError!);
        return false;
      }
    }

    _speech ??= stt.SpeechToText();
    try {
      _initialized = await _speech!.initialize(
        onStatus: onStatus == null ? null : (status) => onStatus(status),
        onError: (error) {
          _lastError = _friendlySpeechError(error.errorMsg);
          onError?.call(_lastError!);
        },
      );
    } catch (e) {
      _initialized = false;
      _lastError = 'تعذر تشغيل خدمة التعرف على الكلام: $e';
      onError?.call(_lastError!);
      return false;
    }

    if (_initialized) {
      _preferredArabicLocale = await _pickArabicLocale();
      if (_preferredArabicLocale == null) {
        _lastError =
            'سأحاول الاستماع بالعربية المصرية. لا تحتاج تغيير لغة الهاتف كلها؛ لو ظهر الكلام إنجليزي فعّل العربية في الإملاء الصوتي أو Google Voice Typing فقط.';
        _preferredArabicLocale = 'ar_EG';
      }
    } else {
      _lastError = kIsWeb
          ? 'خدمة تحويل الصوت إلى كلام غير متاحة في هذا المتصفح. اكتب الرسالة أو استخدم ميكروفون الكيبورد.'
          : 'خدمة التعرف على الكلام غير متاحة على هذا الهاتف.';
      onError?.call(_lastError!);
    }
    return _initialized;
  }

  Future<String?> _pickArabicLocale() async {
    if (_speech == null) return null;
    try {
      final locales = await _speech!.locales();
      final ids = locales.map((l) => l.localeId).toList();
      for (final wanted in ['ar_EG', 'ar-EG', 'ar']) {
        final match = ids
            .where((id) => id.toLowerCase() == wanted.toLowerCase())
            .toList();
        if (match.isNotEmpty) return match.first;
      }
      final anyArabic =
          ids.where((id) => id.toLowerCase().startsWith('ar')).toList();
      if (anyArabic.isNotEmpty) return anyArabic.first;
    } catch (e) {
      _lastError = 'تعذر قراءة لغات التعرف على الكلام: $e';
    }
    return 'ar_EG';
  }

  Future<void> startListening(
    Function(String result, bool isFinal) onResult, {
    Function(String error)? onError,
    Function(String status)? onStatus,
    String? localeId,
  }) async {
    if (!_initialized) {
      await initialize(onStatus: onStatus, onError: onError);
    }
    if (_speech == null || !_initialized) {
      onError?.call(_lastError ?? 'خدمة التعرف على الكلام غير جاهزة.');
      return;
    }

    final selectedLocale = localeId ?? _preferredArabicLocale ?? 'ar_EG';

    try {
      await _speech!.listen(
        onResult: (result) {
          final words = result.recognizedWords.trim();
          if (words.isNotEmpty) {
            // Android devices sometimes never send finalResult=true. Keep partial
            // words so the user can stop and confirm instead of losing the voice text.
            onResult(words, result.finalResult);
          }
        },
        localeId: selectedLocale,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
        cancelOnError: false,
        listenMode: stt.ListenMode.dictation,
      );
    } catch (e) {
      _lastError =
          'فشل بدء التسجيل الصوتي باللغة $selectedLocale. اكتب الرسالة أو استخدم ميكروفون الكيبورد: $e';
      onError?.call(_lastError!);
    }
  }

  String _friendlySpeechError(String error) {
    final lower = error.toLowerCase();
    if (kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return 'الصوت داخل نسخة الويب على iPhone غير مدعوم بثبات. استخدم ميكروفون كيبورد الآيفون داخل خانة الكتابة، ثم اضغط إرسال.';
    }
    if (lower.contains('not-allowed') || lower.contains('denied')) {
      return 'إذن الميكروفون مرفوض. افتح إعدادات المتصفح واسمح بالميكروفون لهذا الموقع.';
    }
    if (lower.contains('audio-capture') || lower.contains('audio')) {
      return 'لم أستطع الوصول للميكروفون. تأكد أن الميكروفون غير مستخدم في تطبيق آخر.';
    }
    if (lower.contains('language') || lower.contains('network')) {
      return 'تعذر تشغيل التعرف الصوتي بالعربية. فعّل العربية في الإملاء الصوتي أو استخدم الكتابة.';
    }
    if (lower.contains('no-speech')) {
      return 'لم أسمع كلام واضح. قرّب الهاتف وتكلم مرة أخرى أو اكتب المصروف.';
    }
    return error.isEmpty
        ? 'حدثت مشكلة في الصوت. اكتب الرسالة أو جرّب مرة أخرى.'
        : error;
  }

  Future<void> stopListening() async {
    await _speech?.stop();
  }

  void dispose() {
    _speech?.stop();
  }
}
