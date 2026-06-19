import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:app_links/app_links.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../providers/auth_provider.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _appLinks = AppLinks();

  @override
  void initState() {
    super.initState();
    _navigateAfterDelay();
  }

  bool _hasInvite(Uri? uri) {
    if (uri == null) return false;
    final p = uri.queryParameters;
    return (p['invite'] ?? p['code'] ?? '').trim().isNotEmpty;
  }

  Future<Uri?> _initialInviteLink() async {
    try {
      final link = await _appLinks.getInitialLink();
      if (_hasInvite(link)) return link;
    } catch (_) {}
    if (_hasInvite(Uri.base)) return Uri.base;
    return null;
  }

  Future<void> _navigateAfterDelay() async {
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;

    final auth = context.read<AuthProvider>();
    final inviteLink = await _initialInviteLink();

    // Important: if the app is opened from an invitation, do not restore an old
    // local session. A previous install/session would otherwise jump straight
    // into the old family and the invite would never be applied.
    if (inviteLink != null || Uri.base.queryParameters['reset'] == '1') {
      await auth.signOut();
    }

    await auth.restoreSession();
    if (!mounted) return;

    if (inviteLink != null) {
      Navigator.pushReplacementNamed(
        context,
        '/auth',
        arguments: {'inviteUri': inviteLink.toString()},
      );
      return;
    }

    if (auth.isLoggedIn && auth.group != null) {
      Navigator.pushReplacementNamed(
        context,
        '/chat',
        arguments: {
          'groupId': auth.group!.id,
          'groupName': auth.group!.name,
        },
      );
    } else {
      Navigator.pushReplacementNamed(context, '/auth');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primaryGreen,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.account_balance_wallet_rounded,
                size: 60,
                color: AppTheme.primaryGreen,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Budget Home',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'ميزانية عائلتك بالصوت والمحادثة',
              style: TextStyle(fontSize: 16, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            const Text(
              AppConstants.appVersion,
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 48),
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
