import 'dart:math';
import 'package:uuid/uuid.dart';

class AuthService {
  final _uuid = const Uuid();
  final _random = Random.secure();
  static const defaultCountryCode = '+20';

  // Simulated user creation — no Firebase needed yet.
  String createUserId() => _uuid.v4();

  String normalizePhone(String input) {
    var phone = input.replaceAll(RegExp(r'[^0-9+]'), '');
    if (phone.startsWith('00')) phone = '+${phone.substring(2)}';
    if (phone.startsWith('+')) return phone;
    if (phone.startsWith('0') && phone.length >= 10) {
      return '$defaultCountryCode${phone.substring(1)}';
    }
    if (phone.length >= 8) return '$defaultCountryCode$phone';
    return phone;
  }

  String whatsappPhone(String input) {
    final normalized = normalizePhone(input);
    return normalized.replaceAll('+', '');
  }

  String generateOtp() {
    return List.generate(6, (_) => _random.nextInt(10)).join();
  }

  // In local mode, we don't need actual auth.
  bool isLoggedIn() => true;
}
