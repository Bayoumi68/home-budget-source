import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/constants.dart';
import 'ad_banner_placeholder.dart';

/// Start the Google Mobile Ads SDK (Android/iOS). Called once from main().
void initPlatformAds() {
  unawaited(MobileAds.instance.initialize());
}

/// A real AdMob banner (320x50). Shows the neutral placeholder while loading
/// or if no ad fills — the slot never jumps in height either way.
class PlatformAdBanner extends StatefulWidget {
  const PlatformAdBanner({super.key, this.height = 50});

  final double height;

  @override
  State<PlatformAdBanner> createState() => _PlatformAdBannerState();
}

class _PlatformAdBannerState extends State<PlatformAdBanner> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final ad = BannerAd(
      size: AdSize.banner, // 320x50 — matches the slot height
      adUnitId: AppConstants.adMobBannerUnitId,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          // No fill / no network: dispose and keep the quiet placeholder.
          ad.dispose();
          if (mounted) setState(() => _ad = null);
        },
      ),
    );
    _ad = ad;
    unawaited(ad.load());
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (ad == null || !_loaded) {
      return AdBannerPlaceholder(height: widget.height);
    }
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: Center(
        child: SizedBox(
          width: ad.size.width.toDouble(),
          height: ad.size.height.toDouble(),
          child: AdWidget(ad: ad),
        ),
      ),
    );
  }
}
