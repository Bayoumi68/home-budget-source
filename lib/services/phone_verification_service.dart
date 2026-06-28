import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart'
    show FirebaseAuthPlatform;
import '../config/constants.dart';

/// Phone-ownership verification for login.
///
/// Two strategies, chosen by platform:
///  * Android — a one-tap Phone Number Hint (reads the SIM numbers via a Google
///    system picker, no runtime permission). If the picked SIM number matches
///    the registered phone we treat ownership as proven. When the SIM number is
///    unreadable or does not match, the caller falls back to OTP.
///  * Web (and Android fallback) — Firebase Phone Auth SMS OTP.
///
/// The SIM-hint path is convenience-grade trust (it is not a verifiable auth
/// credential); the OTP path is the strong proof and the only one usable on web.
class PhoneVerificationService {
  PhoneVerificationService();

  static const MethodChannel _hintChannel =
      MethodChannel('budget_home/phone_hint');

  FirebaseAuth get _auth => FirebaseAuth.instance;

  bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Android only: returns the SIM phone number the user picked from the system
  /// hint sheet, or null when unavailable, dismissed, or on any other platform.
  Future<String?> readSimHint() async {
    if (!isAndroid) return null;
    try {
      final phone = await _hintChannel.invokeMethod<String>('requestPhoneHint');
      final clean = phone?.trim() ?? '';
      return clean.isEmpty ? null : clean;
    } catch (_) {
      // No Google Play services / user cancelled / channel missing → fall back.
      return null;
    }
  }

  /// Begins OTP verification for [phoneE164].
  ///
  /// On web returns immediately with a [PhoneOtpStart.codeSent] holding a
  /// [ConfirmationResult]. On Android it may instantly auto-verify (returns
  /// [PhoneOtpStart.autoVerified]) or send a code ([PhoneOtpStart.codeSent]).
  Future<PhoneOtpStart> startOtp(String phoneE164) async {
    if (kIsWeb) {
      // When testing mode is on, app verification is disabled in main.dart, so
      // Firebase uses a mock reCAPTCHA — no widget, no image puzzle. Use the
      // default (mocked) verifier.
      if (kDebugMode || AppConstants.phoneAuthTestingMode) {
        final confirmation = await _auth.signInWithPhoneNumber(phoneE164);
        return PhoneOtpStart.codeSent(
          PhoneOtpSession(confirmationResult: confirmation),
        );
      }
      // Release web: Firebase requires a real reCAPTCHA. Render an INVISIBLE one
      // (silent for the vast majority of users; a challenge only appears for
      // traffic Google flags as suspicious). No container = invisible mode.
      final verifier = RecaptchaVerifier(auth: FirebaseAuthPlatform.instance);
      final confirmation =
          await _auth.signInWithPhoneNumber(phoneE164, verifier);
      return PhoneOtpStart.codeSent(
        PhoneOtpSession(confirmationResult: confirmation),
      );
    }

    final completer = Completer<PhoneOtpStart>();
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneE164,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (credential) {
        if (!completer.isCompleted) {
          completer.complete(PhoneOtpStart.autoVerified(credential));
        }
      },
      verificationFailed: (e) {
        if (!completer.isCompleted) {
          completer.complete(PhoneOtpStart.failed(e.message ?? 'فشل التحقق'));
        }
      },
      codeSent: (verificationId, _) {
        if (!completer.isCompleted) {
          completer.complete(
            PhoneOtpStart.codeSent(
              PhoneOtpSession(verificationId: verificationId),
            ),
          );
        }
      },
      codeAutoRetrievalTimeout: (_) {},
    );
    return completer.future;
  }

  /// Confirms a typed SMS [smsCode] for a previously started [session].
  /// Returns the verified phone number reported by Firebase (may be null on
  /// success if the provider does not echo it). Throws on an invalid code.
  Future<String?> confirmOtp(PhoneOtpSession session, String smsCode) async {
    final UserCredential result;
    if (session.confirmationResult != null) {
      result = await session.confirmationResult!.confirm(smsCode);
    } else if (session.verificationId != null) {
      final credential = PhoneAuthProvider.credential(
        verificationId: session.verificationId!,
        smsCode: smsCode,
      );
      result = await _auth.signInWithCredential(credential);
    } else {
      return null;
    }
    return result.user?.phoneNumber;
  }

  /// Signs in with an Android auto-retrieved credential and returns the verified
  /// phone number.
  Future<String?> confirmAutoCredential(PhoneAuthCredential credential) async {
    final result = await _auth.signInWithCredential(credential);
    return result.user?.phoneNumber;
  }
}

enum PhoneOtpStatus { codeSent, autoVerified, failed }

class PhoneOtpSession {
  final String? verificationId; // mobile path
  final ConfirmationResult? confirmationResult; // web path

  const PhoneOtpSession({this.verificationId, this.confirmationResult});
}

class PhoneOtpStart {
  final PhoneOtpStatus status;
  final PhoneOtpSession? session;
  final PhoneAuthCredential? autoCredential;
  final String? error;

  const PhoneOtpStart._(
    this.status, {
    this.session,
    this.autoCredential,
    this.error,
  });

  factory PhoneOtpStart.codeSent(PhoneOtpSession session) =>
      PhoneOtpStart._(PhoneOtpStatus.codeSent, session: session);

  factory PhoneOtpStart.autoVerified(PhoneAuthCredential credential) =>
      PhoneOtpStart._(PhoneOtpStatus.autoVerified, autoCredential: credential);

  factory PhoneOtpStart.failed(String error) =>
      PhoneOtpStart._(PhoneOtpStatus.failed, error: error);
}
