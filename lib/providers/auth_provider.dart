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

  /// Signed in with a real credential (Google/email) but maybe not in a family.
  bool get isAuthenticated => _authService.isLoggedIn();
  String? get authUid => _authService.currentAuthUid;
  String? get loginEmail => _authService.currentEmail;
  String? get loginName => _authService.currentDisplayName;
  String? get loginPhotoUrl => _authService.currentPhotoUrl;

  // ─── Credential sign-in (no family context yet) ───

  Future<String?> signInWithGoogle() async {
    try {
      await _authService.signInWithGoogle();
      notifyListeners();
      return null;
    } catch (e) {
      return _authError(e);
    }
  }

  Future<String?> signUpWithEmail(String email, String password) async {
    try {
      await _authService.signUpWithEmail(email, password);
      notifyListeners();
      return null;
    } catch (e) {
      return _authError(e);
    }
  }

  Future<String?> signInWithEmail(String email, String password) async {
    try {
      await _authService.signInWithEmail(email, password);
      notifyListeners();
      return null;
    } catch (e) {
      return _authError(e);
    }
  }

  String _authError(Object e) {
    final s = e.toString();
    if (s.contains('email-already-in-use')) {
      return 'هذا البريد مسجّل بالفعل. سجّل الدخول بدل إنشاء حساب.';
    }
    if (s.contains('wrong-password') || s.contains('invalid-credential')) {
      return 'بيانات الدخول غير صحيحة.';
    }
    if (s.contains('user-not-found')) return 'لا يوجد حساب بهذا البريد.';
    if (s.contains('weak-password')) {
      return 'كلمة المرور ضعيفة (6 أحرف على الأقل).';
    }
    if (s.contains('invalid-email')) return 'صيغة البريد غير صحيحة.';
    if (s.contains('operation-not-allowed')) {
      return 'طريقة الدخول غير مفعّلة في Firebase. فعّل Google/Email في الإعدادات.';
    }
    if (s.contains('popup-closed') ||
        s.contains('cancelled') ||
        s.contains('canceled') ||
        s.contains('web-context-canceled')) {
      return 'تم إلغاء تسجيل الدخول.';
    }
    if (s.contains('network')) return 'تحقق من الاتصال بالإنترنت.';
    return 'تعذّر تسجيل الدخول. حاول مرة أخرى.';
  }

  String _resolveName(String typed) {
    final t = typed.trim();
    if (t.isNotEmpty) return t;
    final n = (_authService.currentDisplayName ?? '').trim();
    return n.isEmpty ? 'مستخدم' : n;
  }

  // ─── Create / Join family ───

  /// Returns null on success, or an Arabic error message.
  Future<String?> createFamily(
      String familyName, String phone, String adminName) async {
    final uid = _authService.currentAuthUid;
    if (uid == null) return 'سجّل الدخول أولاً.';
    try {
      final group = await _db.createFamily(
        name: familyName,
        phone: phone,
        adminName: _resolveName(adminName),
        authUid: uid,
        email: _authService.currentEmail,
      );
      final member = await _db.getMember(
            group.id,
            _authService.memberIdForPhone(phone),
          ) ??
          UserModel(
            id: _authService.memberIdForPhone(phone),
            name: _resolveName(adminName),
            phone: phone,
            authUid: uid,
            email: _authService.currentEmail,
            isAdmin: true,
            phoneVerified: true,
          );
      await setSession(member, group);
      return null;
    } on FamilyNameTakenException catch (e) {
      return e.toString();
    } catch (e) {
      return 'تعذّر إنشاء العائلة: $e';
    }
  }

  Future<String?> joinFamily(String groupId, String phone, String name) async {
    final uid = _authService.currentAuthUid;
    if (uid == null) return 'سجّل الدخول أولاً.';
    try {
      final membership = await _db.joinFamily(
        groupId: groupId,
        phone: phone,
        name: _resolveName(name),
        authUid: uid,
        email: _authService.currentEmail,
      );
      await setSession(membership.member, membership.group);
      return null;
    } on JoinFamilyException catch (e) {
      return e.toString();
    } catch (e) {
      return 'تعذّر الانضمام: $e';
    }
  }

  Future<List<FamilyMembership>> myMemberships() async {
    final uid = _authService.currentAuthUid;
    if (uid == null) return const [];
    return _db.getMembershipsByAuthUid(uid);
  }

  Future<void> openMembership(FamilyMembership membership) =>
      setSession(membership.member, membership.group);

  // ─── Session ───

  Future<void> restoreSession() async {
    _loading = true;
    notifyListeners();
    await _db.writeDiagnostic('app_open');

    final uid = _authService.currentAuthUid;
    if (uid == null) {
      _user = null;
      _group = null;
      _team = null;
      _teamId = null;
      _teamOnly = false;
      await _db.clearActiveSession();
      _loading = false;
      notifyListeners();
      return;
    }

    List<FamilyMembership> memberships = const [];
    try {
      memberships = await _db.getMembershipsByAuthUid(uid);
    } catch (_) {
      // e.g. the authUid index is still building, or a transient network error.
      // Don't brick the splash; treat as "no family yet" and let the user retry.
      memberships = const [];
    }
    if (memberships.isEmpty) {
      _user = null;
      _group = null;
    } else {
      final activeGroup = await _db.getActiveGroup();
      final chosen = memberships.firstWhere(
        (m) => m.group.id == activeGroup?.id,
        orElse: () => memberships.first,
      );
      _user = chosen.member;
      _group = chosen.group;
      _team = null;
      _teamId = null;
      _teamOnly = false;
      await _db.saveActiveSession(_user!, _group!);
    }
    _loading = false;
    notifyListeners();
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
    await _db.saveActiveSession(user, group,
        teamId: _teamId, teamOnly: _teamOnly);
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
    _team = null;
    _teamId = null;
    _teamOnly = false;
    await _db.clearActiveSession();
    try {
      await _authService.signOutFirebase();
    } catch (_) {}
    notifyListeners();
  }
}
