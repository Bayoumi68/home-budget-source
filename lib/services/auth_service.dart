import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

class AuthService {
  final _uuid = const Uuid();
  static const defaultCountryCode = '+20';

  FirebaseAuth get _firebaseAuth => FirebaseAuth.instance;

  String? get currentAuthUid {
    try {
      return _firebaseAuth.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  Future<String?> ensureFirebaseIdentity() async {
    try {
      final current = _firebaseAuth.currentUser;
      if (current != null) return current.uid;
      final credential = await _firebaseAuth.signInAnonymously();
      return credential.user?.uid;
    } on FirebaseAuthException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> signOutFirebase() async {
    await _firebaseAuth.signOut();
  }

  // Local fallback ID remains available if Firebase Auth is not enabled yet.
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

  /// Reduces a phone number to its national significant digits so numbers can be
  /// compared regardless of country-code / leading-zero formatting differences
  /// (e.g. "+201001234567", "01001234567", "201001234567" all match).
  String _significantDigits(String input) {
    var digits = normalizePhone(input).replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('20')) digits = digits.substring(2);
    if (digits.startsWith('0')) digits = digits.substring(1);
    return digits;
  }

  /// True when two phone numbers refer to the same line, tolerating formatting.
  bool phonesMatch(String a, String b) {
    final sa = _significantDigits(a);
    final sb = _significantDigits(b);
    if (sa.length < 6 || sb.length < 6) return false;
    return sa == sb || sa.endsWith(sb) || sb.endsWith(sa);
  }

  bool isLoggedIn() => currentAuthUid != null;
}
