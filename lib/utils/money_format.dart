import 'package:intl/intl.dart';

/// The ONE money formatter — every amount the user sees goes through this,
/// so the same value can't render as "1500" on one screen and "1,500" on
/// another (the app previously mixed NumberFormat('#,###'),
/// NumberFormat('#,##0'), and toStringAsFixed(0) per screen).
/// Whole amounts show with thousands separators and no decimals; fractional
/// amounts (rare) keep up to 2 decimals.
final NumberFormat _money = NumberFormat('#,##0.##');

String formatMoney(num amount) => _money.format(amount);
