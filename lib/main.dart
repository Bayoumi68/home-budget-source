import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'package:provider/provider.dart';
import 'config/constants.dart';
import 'config/theme.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/budget_provider.dart';
import 'providers/notification_provider.dart';

import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/team_member_home_screen.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    ErrorWidget.builder = (details) => AppStartupError(
          message: details.exceptionAsString(),
        );
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
    };

    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      FirebaseFirestore.instance.settings =
          const Settings(persistenceEnabled: true);
      // Disable real app verification so phone-auth uses a mock reCAPTCHA.
      // Combined with Firebase test phone numbers this lets the family test the
      // OTP flow with no image puzzle and no real SMS. Gated by a flag so it can
      // be turned off for a real public launch (see AppConstants).
      if (kDebugMode || AppConstants.phoneAuthTestingMode) {
        try {
          await FirebaseAuth.instance
              .setSettings(appVerificationDisabledForTesting: true);
        } catch (_) {}
      }
      runApp(const BudgetHomeApp());
    } catch (e) {
      runApp(AppStartupError(message: e.toString()));
    }
  }, (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack),
    );
  });
}

class AppStartupError extends StatelessWidget {
  final String message;
  const AppStartupError({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: const Color(0xFFF6F2EA),
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        size: 54, color: Colors.red),
                    const SizedBox(height: 16),
                    const Text(
                      'حدثت مشكلة في فتح Home Budget',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'اقفل التطبيق وافتحه مرة أخرى. لو أنت على iPhone جرّب تحديث Safari أو افتح الرابط في Chrome.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class BudgetHomeApp extends StatelessWidget {
  const BudgetHomeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ChatProvider()),
        ChangeNotifierProvider(create: (_) => BudgetProvider()),
        ChangeNotifierProvider(create: (_) => NotificationProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return MaterialApp(
            title: 'Home Budget',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeProvider.mode,
            home: const SplashScreen(),
            onGenerateRoute: (settings) {
              switch (settings.name) {
                case '/auth':
                  final args = settings.arguments as Map<String, dynamic>?;
                  final inviteUri = args?['inviteUri'] == null
                      ? null
                      : Uri.tryParse(args!['inviteUri'].toString());
                  return MaterialPageRoute(
                      builder: (_) => AuthScreen(initialInvite: inviteUri));
                case '/chat':
                  final args = settings.arguments as Map<String, dynamic>?;
                  return MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      groupId: args?['groupId'] ?? '',
                      groupName: args?['groupName'] ?? 'عائلتي',
                    ),
                  );
                case '/team-home':
                  final args = settings.arguments as Map<String, dynamic>?;
                  return MaterialPageRoute(
                    builder: (_) => TeamMemberHomeScreen(
                      groupId: args?['groupId'] ?? '',
                      teamId: args?['teamId'] ?? '',
                    ),
                  );
                default:
                  return MaterialPageRoute(
                      builder: (_) => const SplashScreen());
              }
            },
          );
        },
      ),
    );
  }
}
