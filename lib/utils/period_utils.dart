import 'package:flutter/material.dart';

/// Shared period logic for report screens (today/week/month/quarter/all/custom)
/// — was byte-for-byte duplicated between analytics_screen.dart and
/// team_analytics_screen.dart; one definition now, so a period-logic fix only
/// has to happen once.
class PeriodUtils {
  static const Map<String, String> labels = {
    'today': 'اليوم',
    'week': 'أسبوع',
    'month': 'هذا الشهر',
    'quarter': '٣ شهور',
    'all': 'الكل',
    'custom': 'مخصص',
  };

  static DateTime start(String period, DateTimeRange? customRange) {
    final now = DateTime.now();
    switch (period) {
      case 'today':
        return DateTime(now.year, now.month, now.day);
      case 'week':
        return DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 6));
      case 'month':
        return DateTime(now.year, now.month, 1);
      case 'quarter':
        return DateTime(now.year, now.month - 2, 1);
      case 'all':
        return DateTime(2000);
      case 'custom':
        return customRange == null ? DateTime(2000) : customRange.start;
      default:
        return DateTime(now.year, now.month, 1);
    }
  }

  static DateTime end(String period, DateTimeRange? customRange) {
    if (period == 'custom' && customRange != null) {
      final e = customRange.end;
      return DateTime(e.year, e.month, e.day, 23, 59, 59);
    }
    return DateTime.now();
  }

  static bool inPeriod(DateTime d, String period, DateTimeRange? customRange) =>
      !d.isBefore(start(period, customRange)) &&
      !d.isAfter(end(period, customRange));

  /// Handles a period-dropdown change, including the 'custom' range picker.
  /// Returns the new (period, range) pair, or null if nothing should change
  /// (no value picked, or the custom-range dialog was cancelled).
  static Future<({String period, DateTimeRange? range})?> pickPeriod(
    BuildContext context,
    String? newValue,
    DateTimeRange? currentRange,
  ) async {
    if (newValue == null) return null;
    if (newValue == 'custom') {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: now,
        initialDateRange: currentRange ??
            DateTimeRange(
                start: now.subtract(const Duration(days: 7)), end: now),
      );
      if (picked == null) return null;
      return (period: 'custom', range: picked);
    }
    return (period: newValue, range: currentRange);
  }
}
