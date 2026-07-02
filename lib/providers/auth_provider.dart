import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../models/user_model.dart';
import '../models/group_model.dart';
import '../models/team_model.dart';
import '../utils/web_url.dart';

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

  /// Self-join via a one-time invite code. Returns null on success, else error.
  Future<String?> joinByCode(String code, String name, String? phone) async {
    final uid = _authService.currentAuthUid;
    if (uid == null) return 'سجّل الدخول أولاً.';
    try {
      final membership = await _db.joinByCode(
        code: code,
        name: _resolveName(name),
        phone: phone,
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

  /// Recovery: claim every family slot registered to [phone] by binding it to
  /// the current Google login. Phone is the join key across the app, so this
  /// restores an admin (or any member) whose authUid binding got tangled —
  /// without deleting or changing anything else. Returns null on success,
  /// otherwise an Arabic error. On success [count] slots were (re)bound.
  Future<String?> restoreByPhone(String phone) async {
    final uid = _authService.currentAuthUid;
    if (uid == null) return 'سجّل الدخول أولاً.';
    final normalized = _authService.normalizePhone(phone);
    if (normalized.length < 8) return 'اكتب رقم موبايل صحيح.';
    // Rebind ALL matching slots (admin + member) — not deduped by family — so a
    // tangled admin binding is restored even if another slot shares the phone.
    final bound = await _db.rebindMembersByPhone(normalized, uid);
    if (bound == 0) return 'لم أجد أي حساب مرتبط بهذا الرقم.';
    return null;
  }

  Future<void> openMembership(FamilyMembership membership) async {
    var m = membership.member;
    // Self-heal: if this slot was found by email but its authUid is stale or
    // missing, bind it to the current login so it's found by authUid next time.
    final uid = _authService.currentAuthUid;
    if (uid != null && uid.isNotEmpty && m.authUid != uid) {
      try {
        m = await _db.bindMemberAuthUid(membership.group.id, m, uid);
      } catch (_) {
        // Non-fatal: opening the session still works without the rebind.
      }
    }
    if (m.isWorker) {
      // A worker enters a team-only view of their own data, never the family.
      final team = await _db.getTeamById(membership.group.id, m.teamId!);
      await setSession(m, membership.group, team: team, teamOnly: true);
    } else {
      await setSession(m, membership.group);
    }
  }

  // ─── Session ───

  Future<void> restoreSession() async {
    _loading = true;
    notifyListeners();
    // Wait for Firebase to restore a persisted login before deciding where to
    // route — otherwise a signed-in user gets bounced to the login screen.
    await _authService.waitForAuthReady();
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
      final activeUser = await _db.getActiveUser();
      // Prefer the exact member last chosen (handles one login bound to more
      // than one member in the same family), then any member of that family.
      final chosen = memberships.firstWhere(
        (m) => m.group.id == activeGroup?.id && m.member.id == activeUser?.id,
        orElse: () => memberships.firstWhere(
          (m) => m.group.id == activeGroup?.id,
          orElse: () => memberships.first,
        ),
      );
      _user = chosen.member;
      _group = chosen.group;
      if (chosen.member.isWorker) {
        // Restore a worker straight into their team-only view.
        _team = await _db.getTeamById(chosen.group.id, chosen.member.teamId!);
        _teamId = chosen.member.teamId;
        _teamOnly = true;
      } else {
        _team = null;
        _teamId = null;
        _teamOnly = false;
      }
      await _db.saveActiveSession(_user!, _group!,
          teamId: _teamId, teamOnly: _teamOnly);
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

  /// Edit your OWN display name (works for the admin too). Updates the member
  /// row and the live session.
  Future<void> updateMyName(String name) async {
    final n = name.trim();
    if (_user == null || _group == null || n.isEmpty) return;
    final updated = _user!.copyWith(name: n);
    _user = updated;
    await _db.updateMemberNameLimit(_group!.id, updated.id, name: n);
    await _db.saveActiveSession(updated, _group!);
    notifyListeners();
  }

  /// Replace the live session with a fully different member record — used
  /// after changeJoinedMemberPhone, where the current user's OWN id/phone
  /// just changed (their old member doc no longer exists), so the normal
  /// refreshCurrentUser (which re-fetches by the now-stale old id) can't work.
  Future<void> replaceCurrentUser(UserModel updated) async {
    if (_group == null) return;
    _user = updated;
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
    // Web is a single-page app — the browser's address bar still carries
    // whatever invite link (groupId/phone/invite/code) the tab was opened
    // with. Left alone, the next auth screen re-reads it and re-shows the
    // join flow for someone who already left. Reset it to the plain app URL.
    clearInviteFromBrowserUrl();
    notifyListeners();
  }

  /// Drop the chosen family/member but STAY signed in with the same Google
  /// account, so the auth screen shows the membership picker again. Useful when
  /// one login is tied to more than one family/member (e.g. admin + a child).
  Future<void> switchAccount() async {
    _user = null;
    _group = null;
    _team = null;
    _teamId = null;
    _teamOnly = false;
    await _db.clearActiveSession();
    clearInviteFromBrowserUrl();
    notifyListeners();
  }
}
