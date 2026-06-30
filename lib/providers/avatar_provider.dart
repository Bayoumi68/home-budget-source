import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../services/database_service.dart';

/// Holds the family's profile photos (decoded bytes, keyed by member id) so any
/// screen can show a member's avatar by id. Photos live in Firestore
/// (families/{groupId}/avatars/{memberId}) and are shared across all devices.
class AvatarProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();
  final Map<String, Uint8List> _avatars = {};

  /// Decoded photo bytes for [memberId], or null if none.
  Uint8List? bytesFor(String? memberId) =>
      (memberId == null || memberId.isEmpty) ? null : _avatars[memberId];

  /// Load (or reload) every avatar for the family.
  Future<void> load(String groupId) async {
    try {
      final raw = await _db.getAvatars(groupId);
      _avatars.clear();
      raw.forEach((id, b64) {
        try {
          if (b64.isNotEmpty) _avatars[id] = base64Decode(b64);
        } catch (_) {}
      });
      notifyListeners();
    } catch (_) {
      // Keep whatever we already have on a transient failure.
    }
  }

  /// Save [bytes] as [memberId]'s photo: update locally for an instant refresh,
  /// then persist to Firestore so the rest of the family sees it.
  Future<void> setAvatar(
      String groupId, String memberId, Uint8List bytes) async {
    if (memberId.isEmpty || bytes.isEmpty) return;
    _avatars[memberId] = bytes;
    notifyListeners();
    try {
      await _db.setAvatar(groupId, memberId, base64Encode(bytes));
    } catch (_) {}
  }
}
