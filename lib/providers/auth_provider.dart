import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../models/user_model.dart';
import '../models/group_model.dart';

class AuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();
  final DatabaseService _db = DatabaseService();

  UserModel? _user;
  GroupModel? _group;
  bool _loading = false;

  UserModel? get user => _user;
  GroupModel? get group => _group;
  bool get loading => _loading;
  bool get isLoggedIn => _user != null && _group != null;

  Future<void> restoreSession() async {
    _loading = true;
    notifyListeners();
    await _db.writeDiagnostic('app_open');

    // In the web test phase, clear any local session from older builds.
    // Otherwise the user can land directly in an old local family while Firestore stays empty.
    final currentBuildSession = await _db.isSessionVersionCurrent();
    if (!currentBuildSession) {
      await _db.clearActiveSession();
    }

    _user = await _db.getActiveUser();
    _group = await _db.getActiveGroup();
    if (_user != null && _group != null) {
      // Important for the web/Firebase test: older local builds saved sessions in
      // SharedPreferences without creating the Firestore family document. If we
      // restore that stale local session, the app looks logged in but nothing is
      // written to Firestore. Force the user back to a clean Firebase-backed login.
      final freshGroup = await _db.getGroupById(_group!.id);
      if (freshGroup == null) {
        await _db.clearActiveSession();
        _user = null;
        _group = null;
      } else {
        _group = freshGroup;
        final freshMember = await _db.getMember(_group!.id, _user!.id);
        if (freshMember != null) _user = freshMember;
      }
    }
    _loading = false;
    notifyListeners();
  }

  UserModel createUser(String name, {String? phone, bool isAdmin = false}) {
    final normalizedPhone = _authService.normalizePhone(phone ?? '');
    _user = UserModel(
      id: normalizedPhone.isNotEmpty ? 'phone_$normalizedPhone' : _authService.createUserId(),
      name: name,
      phone: normalizedPhone.isEmpty ? null : normalizedPhone,
      isAdmin: isAdmin,
      canAddExpenses: true,
      canViewReports: true,
      canManageMembers: isAdmin,
      canManageBudgets: isAdmin,
    );
    notifyListeners();
    return _user!;
  }

  Future<void> setSession(UserModel user, GroupModel group) async {
    _user = user;
    _group = group;
    await _db.saveActiveSession(user, group);
    notifyListeners();
  }

  Future<void> refreshCurrentUser() async {
    if (_user == null || _group == null) return;
    final fresh = await _db.getMember(_group!.id, _user!.id);
    if (fresh != null) {
      _user = fresh;
      await _db.saveActiveSession(fresh, _group!);
      notifyListeners();
    }
  }

  Future<void> updateProfilePhoto(String photoPath) async {
    if (_user == null || _group == null) return;
    final updated = _user!.copyWith(photoUrl: photoPath);
    _user = updated;
    await _db.updateMemberPhoto(_group!.id, updated.id, photoPath);
    await _db.saveActiveSession(updated, _group!);
    notifyListeners();
  }

  void setAdmin(bool admin) {
    _user = _user?.copyWith(
      isAdmin: admin,
      canManageMembers: admin,
      canManageBudgets: admin,
    );
    notifyListeners();
  }

  Future<void> signOut() async {
    _user = null;
    _group = null;
    await _db.clearActiveSession();
    notifyListeners();
  }
}
