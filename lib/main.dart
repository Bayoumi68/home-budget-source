import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'package:provider/provider.dart';
import 'config/theme.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/budget_provider.dart';
import 'providers/notification_provider.dart';

import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/chat_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseFirestore.instance.settings =
      const Settings(persistenceEnabled: true);
  runApp(const BudgetHomeApp());
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
            title: 'Budget Home',
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
