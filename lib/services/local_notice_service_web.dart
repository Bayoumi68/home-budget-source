import 'dart:html' as html;

class LocalNoticeService {
  const LocalNoticeService();

  Future<void> requestPermission() async {
    if (!html.Notification.supported) return;
    if (html.Notification.permission == 'default') {
      await html.Notification.requestPermission();
    }
  }

  void show(String title, String body) {
    if (!html.Notification.supported) return;
    if (html.Notification.permission != 'granted') return;
    html.Notification(
      title,
      body: body,
      dir: 'rtl',
      lang: 'ar',
      icon: 'icons/Icon-192.png',
    );
  }
}
