import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import '../config/constants.dart';
import 'ad_banner_placeholder.dart';

/// No SDK to start on web — AdSense loads through a script tag on demand.
void initPlatformAds() {}

const _viewType = 'adsense-banner';
bool _setupDone = false;

/// Injects the AdSense loader script once and registers the platform view
/// that hosts the <ins class="adsbygoogle"> element. Only runs when a client
/// id is configured — Google has no test mode for web AdSense, so until the
/// account is approved the slot stays on the placeholder.
void _ensureSetup() {
  if (_setupDone) return;
  _setupDone = true;
  final loader = html.ScriptElement()
    ..src = 'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'
        '?client=${AppConstants.adSenseClientId}'
    ..async = true
    ..crossOrigin = 'anonymous';
  html.document.head!.append(loader);
  ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
    final ins = html.Element.tag('ins')
      ..className = 'adsbygoogle'
      ..style.display = 'inline-block'
      ..style.width = '320px'
      ..style.height = '50px'
      ..setAttribute('data-ad-client', AppConstants.adSenseClientId)
      ..setAttribute('data-ad-slot', AppConstants.adSenseSlotId);
    // A DOM-appended <script> executes — asks AdSense to fill the slot above.
    final push = html.ScriptElement()
      ..text = '(adsbygoogle = window.adsbygoogle || []).push({});';
    return html.DivElement()
      ..style.textAlign = 'center'
      ..append(ins)
      ..append(push);
  });
}

class PlatformAdBanner extends StatelessWidget {
  const PlatformAdBanner({super.key, this.height = 50});

  final double height;

  @override
  Widget build(BuildContext context) {
    if (AppConstants.adSenseClientId.isEmpty ||
        AppConstants.adSenseSlotId.isEmpty) {
      return AdBannerPlaceholder(height: height);
    }
    _ensureSetup();
    return SizedBox(
      height: height,
      width: double.infinity,
      child: const HtmlElementView(viewType: _viewType),
    );
  }
}
