class AppConstants {
  static const String appName = 'Home Budget';
  static const String appWebLink = 'https://home-budgets.web.app';
  static const String androidDownloadLink =
      'https://home-budgets.web.app/download.html';
  static const String appVersion = '0.5.23-team-only';
  // TESTING: when true, phone-auth uses Firebase's app-verification-disabled
  // mode + test phone numbers — no reCAPTCHA image puzzle, no real SMS. This
  // applies to release/deployed builds too, so the family can test now. Set to
  // FALSE before a real public launch so genuine reCAPTCHA / Play Integrity
  // protection is enforced.
  static const bool phoneAuthTestingMode = true;
  static const String defaultCurrency = 'EGP';
  static const String aiAssistantName = 'مساعد العائلة';
  static const int maxFamilyMembers = 10;
  static const int maxMessageLength = 500;
  static const Duration voiceMaxDuration = Duration(seconds: 30);

  static const List<String> expenseCategories = [
    'أكل ومشروبات',
    'مواصلات',
    'إيجار',
    'كهرباء',
    'مياه',
    'غاز',
    'إنترنت',
    'اتصالات',
    'تعليم',
    'صحة',
    'ملابس',
    'منظفات',
    'صيانة',
    'أجهزة منزلية',
    'اشتراكات',
    'رسوم وخدمات',
    'ترفيه',
    'هدايا',
    'أخرى',
  ];

  static const List<String> incomeCategories = [
    'راتب',
    'عمل حر',
    'هدية',
    'استثمار',
    'أخرى',
  ];

  static const Map<String, String> categoryIcons = {
    'أكل ومشروبات': '🍽️',
    'مواصلات': '🚗',
    'إيجار': '🏠',
    'كهرباء': '💡',
    'مياه': '🚰',
    'غاز': '🔥',
    'إنترنت': '🌐',
    'اتصالات': '📱',
    'تعليم': '📚',
    'صحة': '💊',
    'ملابس': '👕',
    'منظفات': '🧼',
    'صيانة': '🛠️',
    'أجهزة منزلية': '🔌',
    'اشتراكات': '🧾',
    'رسوم وخدمات': '🏛️',
    'ترفيه': '🎮',
    'هدايا': '🎁',
    'أخرى': '📌',
    'راتب': '💰',
    'عمل حر': '💼',
    'هدية': '🎀',
    'استثمار': '📈',
  };
}
