import 'package:flutter_test/flutter_test.dart';
import 'package:budget_home/services/auth_service.dart';

void main() {
  group('AuthService.normalizePhone', () {
    final auth = AuthService();

    test('adds Egypt country code to local mobile numbers', () {
      expect(auth.normalizePhone('01012345678'), '+201012345678');
      expect(auth.normalizePhone('1012345678'), '+201012345678');
    });

    test('keeps explicit country codes and converts 00 prefix', () {
      expect(auth.normalizePhone('+966501234567'), '+966501234567');
      expect(auth.normalizePhone('00201012345678'), '+201012345678');
    });

    test('removes spaces and symbols before normalizing', () {
      expect(auth.normalizePhone('010 1234-5678'), '+201012345678');
    });
  });
}
