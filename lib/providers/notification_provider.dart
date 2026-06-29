import 'dart:async';
import 'package:flutter/material.dart';
import '../models/family_notification_model.dart';
import '../services/database_service.dart';

class NotificationProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();
  List<FamilyNotificationModel> _items = [];
  StreamSubscription<List<FamilyNotificationModel>>? _sub;
  String? _currentUserId;
  bool _isAdmin = false;

  List<FamilyNotificationModel> get items => _items;

  /// Admin sees every family notification. A member sees only notifications
  /// about their own activity (actor) or ones explicitly targeted to them.
  List<FamilyNotificationModel> get visibleItems {
    final uid = _currentUserId;
    if (uid == null || _isAdmin) return _items;
    return _items
        .where((n) => n.actorId == uid || n.targetUserIds.contains(uid))
        .toList();
  }

  int get unreadCount {
    final uid = _currentUserId;
    if (uid == null) return _items.where((n) => !n.read).length;
    return visibleItems.where((n) => !n.isReadFor(uid)).length;
  }

  FamilyNotificationModel? latestUnreadFromOther(String? userId) {
    if (userId == null) return null;
    for (final item in visibleItems) {
      if (item.actorId != userId && !item.isReadFor(userId)) return item;
    }
    return null;
  }

  Future<void> load(String groupId) async {
    _items = await _db.getNotificationsSync(groupId);
    notifyListeners();
  }

  void subscribe(String groupId, String userId, {bool isAdmin = false}) {
    _currentUserId = userId;
    _isAdmin = isAdmin;
    _sub?.cancel();
    _sub = _db.watchNotifications(groupId).listen((items) {
      _items = items;
      notifyListeners();
    });
  }

  Future<void> markAllRead(String groupId, String userId) async {
    await _db.markNotificationsRead(groupId, userId);
    await load(groupId);
  }

  Future<void> clear(String groupId) async {
    await _db.clearNotifications(groupId);
    await load(groupId);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
