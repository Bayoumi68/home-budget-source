class AppConstants {
  static const String appName = 'Home Budgets';
  static const String appWebLink = 'https://home-budgets.web.app';
  static const String androidDownloadLink =
      'https://home-budgets.web.app/download.html';
  static const String appVersion = '0.5.76-fix-launch-crash';
  // Monotonic build number, kept in sync with pubspec (+NNNN). Used to detect a
  // newer release via appConfig/latest. BUMP THIS with every release.
  static const int appBuild = 2076;
  // TESTING: when true, phone-auth uses Firebase's app-verification-disabled
  // mode + test phone numbers — no reCAPTCHA image puzzle, no real SMS. This
  // applies to release/deployed builds too, so the family can test now. Set to
  // FALSE before a real public launch so genuine reCAPTCHA / Play Integrity
  // protection is enforced.
  static const bool phoneAuthTestingMode = true;
  // ── Ads (bottom banner slot, see widgets/ad_banner_slot.dart) ──
  // Master switch: false collapses the slot everywhere. Currently the slot
  // shows a placeholder — the real google_mobile_ads SDK crashed the app on
  // launch on-device and was rolled back; re-enabling it needs a tethered
  // phone to read the native crash first (see ad_banner_slot.dart).
  static const bool adBannerEnabled = true;
  static const String defaultCurrency = 'EGP';
  static const String aiAssistantName = 'مساعد العائلة';
  static const int maxFamilyMembers = 10;
  static const int maxMessageLength = 500;
  static const Duration voiceMaxDuration = Duration(seconds: 30);
}
