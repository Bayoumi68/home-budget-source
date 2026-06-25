class AppConstants {
  static const String appName = 'Budget Home';
  static const String appWebLink = 'https://budget-home-family-test.web.app';
  static const String androidDownloadLink =
      'https://budget-home-family-test.web.app/download.html';
  static const String appVersion = '0.5.19-restore-budget-period';
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
