import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

class AuthService {
  final _uuid = const Uuid();
  final _random = Random.secure();
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

  String generateOtp() {
    return List.generate(6, (_) => _random.nextInt(10)).join();
  }

  bool isLoggedIn() => currentAuthUid != null;
}
