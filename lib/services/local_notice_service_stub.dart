import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Non-web implementation. Only Android is wired up (this app has no iOS/desktop
/// build); any other platform behaves as a silent no-op, same as before.
class LocalNoticeService {
  const LocalNoticeService();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: androidInit));
  }

  Future<void> requestPermission() async {
    if (!Platform.isAndroid) return;
    await _ensureInitialized();
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  void show(String title, String body) {
    if (!Platform.isAndroid) return;
    _ensureInitialized().then((_) {
      const androidDetails = AndroidNotificationDetails(
        'family_notifications',
        'إشعارات العائلة',
        channelDescription: 'إشعارات المصاريف والحركات المالية للعائلة',
        importance: Importance.high,
        priority: Priority.high,
      );
      _plugin.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        const NotificationDetails(android: androidDetails),
      );
    });
  }
}
