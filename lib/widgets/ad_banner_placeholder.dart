import 'package:flutter/material.dart';

/// The neutral strip shown in the ad slot while an ad is loading, when one
/// fails to load, or on web until an AdSense account is connected.
class AdBannerPlaceholder extends StatelessWidget {
  const AdBannerPlaceholder({super.key, this.height = 50});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      color: Colors.grey.shade200,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.campaign_outlined, size: 18, color: Colors.grey.shade500),
          const SizedBox(width: 6),
          Text(
            'مساحة إعلانية',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}
