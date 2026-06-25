import 'dart:async';
import 'package:flutter/material.dart';
import '../models/family_notification_model.dart';
import '../services/database_service.dart';

class NotificationProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();
  List<FamilyNotificationModel> _items = [];
  StreamSubscription<List<FamilyNotificationModel>>? _sub;
  String? _currentUserId;

  List<FamilyNotificationModel> get items => _items;
  List<FamilyNotificationModel> get visibleItems => _currentUserId == null
      ? _items
      : _items.where((n) => n.isVisibleFor(_currentUserId!)).toList();
  int get unreadCount => _items
      .where((n) => _currentUserId == null
          ? !n.read
          : n.isVisibleFor(_currentUserId!) && !n.isReadFor(_currentUserId!))
      .length;

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

  void subscribe(String groupId, String userId) {
    _currentUserId = userId;
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
