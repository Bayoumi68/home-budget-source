import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../models/user_model.dart';
import '../models/group_model.dart';
import '../models/team_model.dart';

class AuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();
  final DatabaseService _db = DatabaseService();

  UserModel? _user;
  GroupModel? _group;
  String? _teamId;
  TeamModel? _team;
  bool _teamOnly = false;
  bool _loading = false;

  UserModel? get user => _user;
  GroupModel? get group => _group;
  String? get teamId => _teamId;
  TeamModel? get team => _team;
  bool get isTeamOnly => _teamOnly;
  bool get loading => _loading;
  bool get isLoggedIn => _user != null && _group != null;
  String? get authUid => _authService.currentAuthUid;

  Future<String?> ensureFirebaseIdentity() =>
      _authService.ensureFirebaseIdentity();

  Future<void> restoreSession() async {
    _loading = true;
    notifyListeners();
    final uid = await ensureFirebaseIdentity();
    await _db.writeDiagnostic('app_open');

    // In the web test phase, clear any local session from older builds.
    // Otherwise the user can land directly in an old local family while Firestore stays empty.
    final currentBuildSession = await _db.isSessionVersionCurrent();
    if (!currentBuildSession) {
      await _db.clearActiveSession();
    }

    _user = await _db.getActiveUser();
    _group = await _db.getActiveGroup();
    _teamId = await _db.getActiveTeamId();
    _teamOnly = await _db.isActiveTeamOnlySession();
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
        if (_teamOnly && (_teamId ?? '').isNotEmpty) {
          final freshTeam = await _db.getTeamById(_group!.id, _teamId!);
          if (freshTeam == null || !freshTeam.hasMember(_user!.id)) {
            await _db.clearActiveSession();
            _user = null;
            _group = null;
            _team = null;
            _teamId = null;
            _teamOnly = false;
          } else {
            _team = freshTeam;
            _user = _user!.copyWith(
              name: freshTeam.memberNames[_user!.id] ?? _user!.name,
              phone: freshTeam.memberPhones[_user!.id] ?? _user!.phone,
              canViewReports: false,
              canManageMembers: false,
              canManageBudgets: false,
            );
          }
        } else {
          _teamOnly = false;
          _team = null;
          _teamId = null;
          final freshMember = await _db.getMember(_group!.id, _user!.id);
          if (freshMember != null) {
            _user = freshMember;
            if (uid != null && freshMember.authUid != uid) {
              _user = await _db.bindMemberAuthUid(_group!.id, freshMember, uid);
            }
          }
        }
      }
    }
    _loading = false;
    notifyListeners();
  }

  UserModel createUser(
    String name, {
    String? phone,
    bool isAdmin = false,
    bool phoneVerified = false,
  }) {
    final normalizedPhone = _authService.normalizePhone(phone ?? '');
    _user = UserModel(
      id: normalizedPhone.isNotEmpty
          ? 'phone_$normalizedPhone'
          : _authService.createUserId(),
      name: name,
      phone: normalizedPhone.isEmpty ? null : normalizedPhone,
      authUid: _authService.currentAuthUid,
      isAdmin: isAdmin,
      canAddExpenses: true,
      canViewReports: true,
      canManageMembers: isAdmin,
      canManageBudgets: isAdmin,
      phoneVerified: phoneVerified,
    );
    notifyListeners();
    return _user!;
  }

  Future<void> setSession(
    UserModel user,
    GroupModel group, {
    TeamModel? team,
    bool teamOnly = false,
  }) async {
    _user = user;
    _group = group;
    _team = team;
    _teamId = team?.id;
    _teamOnly = teamOnly && team != null;
    await _db.saveActiveSession(
      user,
      group,
      teamId: _teamId,
      teamOnly: _teamOnly,
    );
    notifyListeners();
  }

  Future<void> refreshCurrentUser() async {
    if (_user == null || _group == null) return;
    if (_teamOnly && (_teamId ?? '').isNotEmpty) {
      final freshTeam = await _db.getTeamById(_group!.id, _teamId!);
      if (freshTeam != null && freshTeam.hasMember(_user!.id)) {
        _team = freshTeam;
        _user = _user!.copyWith(
          name: freshTeam.memberNames[_user!.id] ?? _user!.name,
          phone: freshTeam.memberPhones[_user!.id] ?? _user!.phone,
        );
        await _db.saveActiveSession(
          _user!,
          _group!,
          teamId: freshTeam.id,
          teamOnly: true,
        );
        notifyListeners();
      }
      return;
    }
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
    _team = null;
    _teamId = null;
    _teamOnly = false;
    await _db.clearActiveSession();
    notifyListeners();
  }
}
