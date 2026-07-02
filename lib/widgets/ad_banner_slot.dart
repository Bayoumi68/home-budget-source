import 'package:flutter/material.dart';

import '../config/constants.dart';
import 'ad_banner_placeholder.dart';

/// Bottom ad slot, mounted app-wide (below the Navigator in main.dart) so it
/// shows on every screen. Currently renders a neutral placeholder strip.
///
/// Real Google ads were attempted via google_mobile_ads but the native SDK
/// crashed the app on launch on-device, and it can't be debugged without a
/// tethered phone to read the crash — so the SDK was rolled back to keep the
/// app launching. To re-enable: re-add google_mobile_ads + the AdMob
/// APPLICATION_ID manifest meta-data, then render the real banner here behind
/// a device-verified integration.
///
/// [AppConstants.adBannerEnabled] = false collapses the slot everywhere.
class AdBannerSlot extends StatelessWidget {
  const AdBannerSlot({super.key});

  static const double _bannerHeight = 50;

  @override
  Widget build(BuildContext context) {
    if (!AppConstants.adBannerEnabled) return const SizedBox.shrink();
    return const SafeArea(
      top: false,
      child: AdBannerPlaceholder(height: _bannerHeight),
    );
  }
}
