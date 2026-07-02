import 'package:flutter/material.dart';

import '../config/constants.dart';
import 'ad_banner_platform_io.dart'
    if (dart.library.html) 'ad_banner_platform_web.dart';

export 'ad_banner_platform_io.dart'
    if (dart.library.html) 'ad_banner_platform_web.dart' show initPlatformAds;

/// The bottom ad banner on the app's main screens (family chat + worker home).
///
/// - Android: a REAL Google AdMob banner — currently on Google's official
///   test ids (safe, clearly-labeled test ads). Swap in your own ids in
///   AppConstants.adMobBannerUnitId + AndroidManifest.xml to go live.
/// - Web: activates the moment AppConstants.adSenseClientId/adSenseSlotId are
///   set (AdSense has no test mode — it needs an approved account); until
///   then it shows the neutral placeholder strip.
/// - AppConstants.adBannerEnabled = false collapses the slot everywhere.
class AdBannerSlot extends StatelessWidget {
  const AdBannerSlot({super.key});

  static const double _bannerHeight = 50;

  @override
  Widget build(BuildContext context) {
    if (!AppConstants.adBannerEnabled) return const SizedBox.shrink();
    return const SafeArea(
      top: false,
      child: PlatformAdBanner(height: _bannerHeight),
    );
  }
}
