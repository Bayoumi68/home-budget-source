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

  /// Every member doc in [groupId] (admin + members), for the recovery picker.
  Future<List<UserModel>> familyMembers(String groupId) =>
      _db.getMembersSync(groupId);

  /// Every account for this login — matched by BOTH authUid and the Google
  /// email (the comprehensive list the picker uses). This is what the recovery
  /// shows, so the user's record appears even if only the uid binding survived.
  Future<List<FamilyMembership>> accountsByEmail() async {
    return myMemberships();
  }

  /// Reconnect a family's designated admin row (`families.adminId`) to the
  /// current Google login. Scenario A: the row exists → rebind it. Scenario B:
  /// the row is missing → recreate it. Returns whether it was recreated, plus
  /// an Arabic error (null on success). Does not touch any other member row.
  Future<({String? error, bool recreated, bool wasWorker})> reconnectAdmin(
      String groupId, String adminId) async {
    final uid = _authService.currentAuthUid;
    if (uid == null) {
      return (error: 'سجّل الدخول أولاً.', recreated: false, wasWorker: false);
    }
    if (adminId.trim().isEmpty) {
      return (
        error: 'لا يوجد معرّف قائد لهذه العائلة.',
        recreated: false,
        wasWorker: false
      );
    }
    try {
      final existing = await _db.getMember(groupId, adminId);
      if (existing != null) {
        final wasWorker = existing.isWorker;
        await _db.reconnectAdminRow(
            groupId, existing, uid, _authService.currentEmail);
        return (error: null, recreated: false, wasWorker: wasWorker);
      }
      await _db.recreateAdminRow(
        groupId,
        adminId,
        uid,
        name: _authService.currentDisplayName ?? 'قائد العائلة',
        email: _authService.currentEmail,
      );
      return (error: null, recreated: true, wasWorker: false);
    } catch (e) {
      return (error: 'تعذّرت الاستعادة: $e', recreated: false, wasWorker: false);
    }
  }

  /// Open a membership by ids, re-fetching fresh (so a just-restored admin role
  /// is reflected in the session). Returns an Arabic error, or null on success.
  Future<String?> openMembershipById(String groupId, String memberId) async {
    final m = await _db.getMember(groupId, memberId);
    final g = await _db.getGroupById(groupId);
    if (m == null || g == null) return 'تعذّر فتح الحساب.';
    await openMembership(FamilyMembership(group: g, member: m));
    return null;
  }

  /// Bind an existing family member doc to the current Google login. When
  /// [makeAdmin] is set, also assert the admin role on that doc AND repoint the
  /// family's adminId at it — so the family has a real, reachable admin again
  /// even if the original admin record was overwritten or orphaned.
  Future<String?> claimMember(String groupId, UserModel member,
      {bool makeAdmin = false}) async {
    final uid = _authService.currentAuthUid;
    if (uid == null) return 'سجّل الدخول أولاً.';
    try {
      await _db.bindMemberAuthUid(groupId, member, uid);
      if (makeAdmin) {
        if (!member.isAdmin) {
          await _db.updateMember(
            groupId,
            member.id,
            (m) => m.copyWith(
              isAdmin: true,
              canManageMembers: true,
              canManageBudgets: true,
              canViewReports: true,
              canAddExpenses: true,
            ),
          );
        }
        await _db.setGroupAdminId(groupId, member.id);
      }
      return null;
    } catch (e) {
      return 'تعذّرت الاستعادة: $e';
    }
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

  Future<void> updateProfilePhoto(String photoPath) async {
    if (_user == null || _group == null) return;
    final updated = _user!.copyWith(photoUrl: photoPath);
    _user = updated;
    await _db.updateMemberPhoto(_group!.id, updated.id, photoPath);
    await _db.saveActiveSession(updated, _group!);
    notifyListeners();
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
    notifyListeners();
  }
}
