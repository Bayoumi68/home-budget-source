class AppConstants {
  static const String appName = 'Home Budgets';
  static const String appWebLink = 'https://home-budgets.web.app';
  static const String androidDownloadLink =
      'https://home-budgets.web.app/download.html';
  static const String appVersion = '0.5.75-app-wide-ad-banner';
  // Monotonic build number, kept in sync with pubspec (+NNNN). Used to detect a
  // newer release via appConfig/latest. BUMP THIS with every release.
  static const int appBuild = 2075;
  // TESTING: when true, phone-auth uses Firebase's app-verification-disabled
  // mode + test phone numbers — no reCAPTCHA image puzzle, no real SMS. This
  // applies to release/deployed builds too, so the family can test now. Set to
  // FALSE before a real public launch so genuine reCAPTCHA / Play Integrity
  // protection is enforced.
  static const bool phoneAuthTestingMode = true;
  // ── Ads (bottom banner slot, see widgets/ad_banner_slot.dart) ──
  // Master switch: false collapses the slot everywhere.
  static const bool adBannerEnabled = true;
  // Android AdMob banner unit. THIS IS GOOGLE'S OFFICIAL TEST ID — it serves
  // real (test-labeled) ads safely today. Before launch: create an AdMob
  // account, register the app, then replace this AND the APPLICATION_ID
  // meta-data in android/app/src/main/AndroidManifest.xml.
  static const String adMobBannerUnitId =
      'ca-app-pub-3940256099942544/6300978111';
  // Web AdSense: Google offers NO test mode for web — it needs an approved
  // AdSense account. Until then leave these empty (the slot shows the
  // placeholder). Once approved, paste your client ('ca-pub-…') and slot ids
  // here — the web banner goes live with no other code change.
  static const String adSenseClientId = '';
  static const String adSenseSlotId = '';
  static const String defaultCurrency = 'EGP';
  static const String aiAssistantName = 'مساعد العائلة';
  static const int maxFamilyMembers = 10;
  static const int maxMessageLength = 500;
  static const Duration voiceMaxDuration = Duration(seconds: 30);
}
