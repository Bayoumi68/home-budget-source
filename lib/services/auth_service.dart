import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Authentication is by real credentials now — Google or email/password.
/// The phone number is NOT a login; it is only a family-level identifier
/// (assigned by the admin, matched on join). No SMS, no SIM, no OTP.
class AuthService {
  static const defaultCountryCode = '+20';

  FirebaseAuth get _auth => FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;
  String? get currentAuthUid => _auth.currentUser?.uid;
  String? get currentEmail => _auth.currentUser?.email;
  String? get currentDisplayName => _auth.currentUser?.displayName;
  String? get currentPhotoUrl => _auth.currentUser?.photoURL;
  bool isLoggedIn() => _auth.currentUser != null;

  /// Google sign-in. Web uses a popup; Android/iOS use the NATIVE account
  /// picker (google_sign_in) — no browser — then exchanges the token with
  /// Firebase.
  Future<UserCredential> signInWithGoogle() async {
    if (kIsWeb) {
      final provider = GoogleAuthProvider()
        ..setCustomParameters({'prompt': 'select_account'});
      return _auth.signInWithPopup(provider);
    }
    final googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) {
      throw FirebaseAuthException(
        code: 'sign_in_canceled',
        message: 'تم إلغاء تسجيل الدخول.',
      );
    }
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
      accessToken: googleAuth.accessToken,
    );
    return _auth.signInWithCredential(credential);
  }

  Future<UserCredential> signUpWithEmail(String email, String password) {
    return _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<UserCredential> signInWithEmail(String email, String password) {
    return _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> signOutFirebase() => _auth.signOut();

  /// Waits until Firebase Auth has restored any persisted session. Right after
  /// app start `currentUser` is null for a moment, so reading it too early would
  /// wrongly send a logged-in user back to the login screen.
  Future<void> waitForAuthReady() async {
    try {
      await _auth.authStateChanges().first.timeout(const Duration(seconds: 6));
    } catch (_) {
      // Timed out / errored — fall back to whatever currentUser is now.
    }
  }

  // ─── Phone helpers (identifier only, not auth) ───

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
  /// compared regardless of country-code / leading-zero formatting differences.
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

  /// Member doc id derived from a phone number (stable within a family).
  String memberIdForPhone(String phone) {
    final n = normalizePhone(phone);
    return 'phone_$n';
  }
}
