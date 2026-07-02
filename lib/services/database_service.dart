import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/user_model.dart';
import '../models/chat_message_model.dart';
import '../models/transaction_model.dart';
import '../models/budget_model.dart';
import '../models/category_model.dart';
import '../models/group_model.dart';
import '../models/family_notification_model.dart';
import '../models/wallet_model.dart';
import '../models/wallet_entry_model.dart';
import '../models/team_model.dart';
import '../config/constants.dart';
import '../data/category_seeds.dart';
import '../services/auth_service.dart';
import '../utils/category_utils.dart';
import '../utils/money_format.dart';
import '../utils/expense_description.dart';

class FamilyMembership {
  final GroupModel group;
  final UserModel member;

  const FamilyMembership({required this.group, required this.member});
}

class TeamMembership {
  final GroupModel group;
  final TeamModel team;
  final UserModel member;

  const TeamMembership({
    required this.group,
    required this.team,
    required this.member,
  });
}

/// V4 Firebase-backed storage.
///
/// Local SharedPreferences are used only for the active device session.
/// Family data is stored under Firestore:
/// families/{groupId}/members
/// families/{groupId}/messages
/// families/{groupId}/transactions
/// families/{groupId}/budgets
/// families/{groupId}/categories
/// families/{groupId}/notifications
/// families/{groupId}/wallets
class DatabaseService {
  static const _activeUserKey = 'active_user';
  static const _activeGroupKey = 'active_group';
  static const _activeTeamKey = 'active_team';
  static const _activeSessionModeKey = 'active_session_mode';
  static const _sessionVersionKey = 'active_app_version';
  static final _secureRandom = Random.secure();
  final _authService = AuthService();
  final _uuid = const Uuid();

  SharedPreferences? _prefs;
  FirebaseFirestore get _fs => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _families =>
      _fs.collection('families');
  CollectionReference<Map<String, dynamic>> get _inviteCodes =>
      _fs.collection('inviteCodes');
  CollectionReference<Map<String, dynamic>> get _familyNames =>
      _fs.collection('familyNames');
  CollectionReference<Map<String, dynamic>> _members(String groupId) =>
      _families.doc(groupId).collection('members');
  CollectionReference<Map<String, dynamic>> _messages(String groupId) =>
      _families.doc(groupId).collection('messages');
  CollectionReference<Map<String, dynamic>> _transactions(String groupId) =>
      _families.doc(groupId).collection('transactions');
  CollectionReference<Map<String, dynamic>> _budgets(String groupId) =>
      _families.doc(groupId).collection('budgets');
  CollectionReference<Map<String, dynamic>> _categories(String groupId) =>
      _families.doc(groupId).collection('categories');
  CollectionReference<Map<String, dynamic>> _notifications(String groupId) =>
      _families.doc(groupId).collection('notifications');
  CollectionReference<Map<String, dynamic>> _wallets(String groupId) =>
      _families.doc(groupId).collection('wallets');
  CollectionReference<Map<String, dynamic>> _teams(String groupId) =>
      _families.doc(groupId).collection('teams');
  // Team-scoped group chat, isolated from the family's main `messages` feed by
  // living under the team's own path — a worker/admin thread per team.
  CollectionReference<Map<String, dynamic>> _teamMessages(
          String groupId, String teamId) =>
      _teams(groupId).doc(teamId).collection('messages');
  CollectionReference<Map<String, dynamic>> _learnedKeywords(String groupId) =>
      _families.doc(groupId).collection('learnedKeywords');
  CollectionReference<Map<String, dynamic>> _avatars(String groupId) =>
      _families.doc(groupId).collection('avatars');

  String _newInviteCode() {
    return List.generate(
      6,
      (_) => _secureRandom.nextInt(10).toString(),
    ).join();
  }

  Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  String _docSafeId(String value) {
    final key = CategoryUtils.key(value);
    return key.isEmpty ? DateTime.now().millisecondsSinceEpoch.toString() : key;
  }

  // ─── Session ───
  Future<void> saveActiveSession(
    UserModel user,
    GroupModel group, {
    String? teamId,
    bool teamOnly = false,
  }) async {
    await _ensurePrefs();
    await _prefs?.setString(_activeUserKey, _encode(user.toMap()));
    await _prefs?.setString(_activeGroupKey, _encode(group.toMap()));
    if (teamId != null && teamId.trim().isNotEmpty) {
      await _prefs?.setString(_activeTeamKey, teamId.trim());
    } else {
      await _prefs?.remove(_activeTeamKey);
    }
    await _prefs?.setString(
        _activeSessionModeKey, teamOnly ? 'team' : 'family');
    await _prefs?.setString(_sessionVersionKey, AppConstants.appVersion);
  }

  Future<bool> isSessionVersionCurrent() async {
    await _ensurePrefs();
    final saved = _prefs?.getString(_sessionVersionKey);
    return saved == AppConstants.appVersion;
  }

  Future<UserModel?> getActiveUser() async {
    await _ensurePrefs();
    final data = _prefs?.getString(_activeUserKey);
    if (data == null) return null;
    return UserModel.fromMap(_decode(data));
  }

  Future<GroupModel?> getActiveGroup() async {
    await _ensurePrefs();
    final data = _prefs?.getString(_activeGroupKey);
    if (data == null) return null;
    return GroupModel.fromMap(_decode(data));
  }

  Future<String?> getActiveTeamId() async {
    await _ensurePrefs();
    final teamId = _prefs?.getString(_activeTeamKey)?.trim();
    return teamId == null || teamId.isEmpty ? null : teamId;
  }

  Future<bool> isActiveTeamOnlySession() async {
    await _ensurePrefs();
    return _prefs?.getString(_activeSessionModeKey) == 'team';
  }

  Future<void> clearActiveSession() async {
    await _ensurePrefs();
    await _prefs?.remove(_activeUserKey);
    await _prefs?.remove(_activeGroupKey);
    await _prefs?.remove(_activeTeamKey);
    await _prefs?.remove(_activeSessionModeKey);
    await _prefs?.remove(_sessionVersionKey);
  }

  // ─── Profile avatars (shared with the whole family) ───
  // Stored as base64 in families/{groupId}/avatars/{memberId} so a member's
  // photo shows on every family member's device (chat bubbles, member cards,
  // header). Kept in its own subcollection so it never bloats member-list reads.
  Future<void> setAvatar(
      String groupId, String memberId, String base64Data) async {
    await _avatars(groupId).doc(memberId).set({
      'data': base64Data,
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  /// All avatars for the family: memberId → base64 string.
  Future<Map<String, String>> getAvatars(String groupId) async {
    final q = await _avatars(groupId).get();
    final map = <String, String>{};
    for (final d in q.docs) {
      final data = (d.data()['data'] ?? '').toString();
      if (data.isNotEmpty) map[d.id] = data;
    }
    return map;
  }

  Future<void> removeAvatar(String groupId, String memberId) async {
    await _avatars(groupId).doc(memberId).delete();
  }

  // ─── In-app update notice ───
  // A single shared pointer (appConfig/latest) records the newest build anyone
  // in the family has run. On launch each device compares its own build:
  //   • newer than (or no) recorded → self-publish this build as the latest,
  //   • older → an update is available (returns the latest version string).
  // This needs no manual deploy step: the first device on a new build (e.g. the
  // freshly-deployed web app) publishes it, and everyone else is then prompted.
  Future<String?> checkForUpdate() async {
    try {
      final ref = _fs.collection('appConfig').doc('latest');
      final snap = await ref.get();
      final data = snap.data();
      final latestBuild = (data?['build'] as num?)?.toInt() ?? 0;
      if (AppConstants.appBuild >= latestBuild) {
        if (AppConstants.appBuild > latestBuild) {
          await ref.set({
            'version': AppConstants.appVersion,
            'build': AppConstants.appBuild,
            'updatedAt': DateTime.now().toIso8601String(),
          });
        }
        return null; // we are the latest
      }
      return (data?['version'] ?? 'نسخة جديدة').toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> writeDiagnostic(String event,
      {String? groupId, String? userId}) async {
    try {
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      await _fs.collection('diagnostics').doc(id).set({
        'event': event,
        'groupId': groupId,
        'userId': userId,
        'appVersion': AppConstants.appVersion,
        'createdAt': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // Keep the app usable even if Firestore rules/network fail; the UI will reveal
      // the issue because families will not appear in the console.
    }
  }

  // ─── Groups ───

  // ─── New auth model: create / join / session-by-login ───

  String _familyNameKey(String name) => CategoryUtils.key(name);

  /// True if a family with this (normalized) name already exists.
  Future<bool> isFamilyNameTaken(String name) async {
    final key = _familyNameKey(name);
    if (key.isEmpty) return false;
    final lock = await _familyNames.doc(key).get();
    if (lock.exists) return true;
    // Fallback for families created before the name-lock existed.
    return (await getGroupByName(name.trim())) != null;
  }

  /// Creates a family with a globally-unique name. Creator becomes admin,
  /// identified by their login [authUid] + [phone]. Throws
  /// [FamilyNameTakenException] if the name is taken.
  Future<GroupModel> createFamily({
    required String name,
    required String phone,
    required String adminName,
    required String authUid,
    String? email,
  }) async {
    final cleanName = name.trim();
    if (await isFamilyNameTaken(cleanName)) {
      throw FamilyNameTakenException(cleanName);
    }
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final inviteCode = _newInviteCode();
    final normalizedPhone = _authService.normalizePhone(phone);
    final nameKey = _familyNameKey(cleanName);
    final admin = UserModel(
      id: _authService.memberIdForPhone(normalizedPhone),
      name: adminName,
      phone: normalizedPhone,
      authUid: authUid,
      email: email,
      isAdmin: true,
      canAddExpenses: true,
      canManageMembers: true,
      canManageBudgets: true,
      phoneVerified: true,
    );
    final group = GroupModel(
      id: id,
      name: cleanName,
      adminId: admin.id,
      members: [admin],
      inviteCode: inviteCode,
    );
    await _familyNames.doc(nameKey).set({
      'name': cleanName,
      'groupId': id,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await _families.doc(id).set({
      ...group.toMap(),
      'nameKey': nameKey,
      'appVersion': AppConstants.appVersion,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await _members(id).doc(admin.id).set({
      ...admin.toMap(),
      'createdAt': DateTime.now().toIso8601String(),
    });
    await _inviteCodes.doc(inviteCode).set({
      'groupId': id,
      'inviteCode': inviteCode,
      'createdAt': DateTime.now().toIso8601String(),
      'appVersion': AppConstants.appVersion,
    });
    await ensureCategoriesSeeded(id);
    await writeDiagnostic('create_family', groupId: id, userId: admin.id);
    return group;
  }

  /// Binds the logged-in user to a member slot in [groupId] for [phone].
  /// Claims the admin-pre-registered slot if present, else creates one.
  Future<FamilyMembership> joinFamily({
    required String groupId,
    required String phone,
    required String name,
    required String authUid,
    String? email,
  }) async {
    final group = await getGroupById(groupId);
    if (group == null) {
      throw JoinFamilyException('لم أجد هذه العائلة. اطلب رابط دعوة جديد.');
    }
    final normalizedPhone = _authService.normalizePhone(phone);
    final memberId = _authService.memberIdForPhone(normalizedPhone);
    final existing = await getMemberByPhone(groupId, normalizedPhone);
    final UserModel toSave;
    if (existing != null) {
      toSave = existing.copyWith(
        id: memberId,
        name: existing.name.trim().isEmpty ? name : existing.name,
        phone: normalizedPhone,
        authUid: authUid,
        email: email,
        phoneVerified: true,
      );
      if (existing.id != memberId) {
        await _members(groupId).doc(existing.id).delete();
      }
    } else {
      toSave = UserModel(
        id: memberId,
        name: name,
        phone: normalizedPhone,
        authUid: authUid,
        email: email,
        canAddExpenses: true,
        canManageMembers: false,
        canManageBudgets: false,
        phoneVerified: true,
      );
    }
    await _members(groupId)
        .doc(toSave.id)
        .set(toSave.toMap(), SetOptions(merge: true));
    return FamilyMembership(group: group, member: toSave);
  }

  /// All family memberships for the signed-in login (for session restore and
  /// the login picker). Matches member docs by [authUid] AND by the Google
  /// account's email — so a family still shows up even if its member doc's
  /// authUid binding got tangled (e.g. one account used for two slots). Both
  /// authUid and email are stamped onto a doc only when that person actually
  /// signs in, so email matching never leaks families the user didn't join.
  Future<List<FamilyMembership>> getMembershipsByAuthUid(String authUid) async {
    final email = (_authService.currentEmail ?? '').trim();
    if (authUid.trim().isEmpty && email.isEmpty) return const [];

    // Key by group + member doc, so if one login maps to more than one member
    // in the same family (e.g. admin + a child) BOTH are offered.
    final byKey = <String, FamilyMembership>{};
    Future<void> ingest(
        Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
      for (final doc in docs) {
        final groupRef = doc.reference.parent.parent;
        if (groupRef == null) continue;
        final member = UserModel.fromMap(doc.data());
        final key = '${groupRef.id}/${member.id}';
        if (byKey.containsKey(key)) continue;
        final group = await getGroupById(groupRef.id);
        if (group == null) continue;
        byKey[key] = FamilyMembership(group: group, member: member);
      }
    }

    if (authUid.trim().isNotEmpty) {
      final q = await _fs
          .collectionGroup('members')
          .where('authUid', isEqualTo: authUid)
          .limit(20)
          .get();
      await ingest(q.docs);
    }
    if (email.isNotEmpty) {
      try {
        final q = await _fs
            .collectionGroup('members')
            .where('email', isEqualTo: email)
            .limit(20)
            .get();
        await ingest(q.docs);
      } catch (_) {
        // The email collection-group index may not be built yet; authUid
        // matches above still cover the normal case.
      }
    }

    final items = byKey.values.toList()
      ..sort((a, b) {
        final g = a.group.name.compareTo(b.group.name);
        return g != 0 ? g : a.member.name.compareTo(b.member.name);
      });
    return items;
  }

  /// EVERY member document whose stored email equals [email], across all
  /// families — no dedup. This is the literal "all accounts for this email"
  /// list. Runs in the signed-in session (the members collection-group is
  /// readable by any authenticated user). Throws if the email index isn't ready
  /// yet, so the caller can surface that instead of hiding it.
  Future<List<FamilyMembership>> membersByEmail(String email) async {
    final e = email.trim();
    if (e.isEmpty) return const [];
    final q = await _fs
        .collectionGroup('members')
        .where('email', isEqualTo: e)
        .limit(40)
        .get();
    final out = <FamilyMembership>[];
    final seen = <String>{};
    for (final doc in q.docs) {
      final groupRef = doc.reference.parent.parent;
      if (groupRef == null) continue;
      final key = '${groupRef.id}/${doc.id}';
      if (seen.contains(key)) continue;
      seen.add(key);
      final group = await getGroupById(groupRef.id);
      if (group == null) continue;
      out.add(FamilyMembership(
          group: group, member: UserModel.fromMap(doc.data())));
    }
    return out;
  }

  /// Admin pre-registers a member slot (pending until they join with their own
  /// credentials). The assigned [phone] is what goes into their invite link.
  Future<UserModel> addPendingMember(
    String groupId, {
    required String name,
    required String phone,
    bool canAddExpenses = true,
    bool canManageBudgets = false,
    bool canManageMembers = false,
    double monthlyLimit = 0,
  }) async {
    final normalizedPhone = _authService.normalizePhone(phone);
    final member = UserModel(
      id: _authService.memberIdForPhone(normalizedPhone),
      name: name,
      phone: normalizedPhone,
      monthlyLimit: monthlyLimit,
      canAddExpenses: canAddExpenses,
      canManageBudgets: canManageBudgets,
      canManageMembers: canManageMembers,
    );
    await _members(groupId).doc(member.id).set({
      ...member.toMap(),
      'createdAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
    return member;
  }

  // Unambiguous one-time code alphabet (no 0/O/1/I).
  String _newOneTimeCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(
        8, (_) => chars[_secureRandom.nextInt(chars.length)]).join();
  }

  /// Create a fresh single-use invite code for a family (or a specific team).
  Future<String> createInvite({
    required String groupId,
    String? teamId,
    String? createdByUid,
  }) async {
    var code = _newOneTimeCode();
    for (var i = 0; i < 5; i++) {
      final existing = await _inviteCodes.doc(code).get();
      if (!existing.exists) break;
      code = _newOneTimeCode();
    }
    await _inviteCodes.doc(code).set({
      'inviteCode': code,
      'groupId': groupId,
      'teamId': teamId ?? '',
      'used': false,
      'createdByUid': createdByUid,
      'createdAt': DateTime.now().toIso8601String(),
      'appVersion': AppConstants.appVersion,
    });
    return code;
  }

  /// Read an invite code's target for display before joining.
  Future<Map<String, dynamic>?> getInviteInfo(String code) async {
    final clean = code.trim().toUpperCase();
    if (clean.isEmpty) return null;
    final data = (await _inviteCodes.doc(clean).get()).data();
    if (data == null) return null;
    final groupId = (data['groupId'] ?? '').toString();
    final teamId = (data['teamId'] ?? '').toString();
    final group = groupId.isEmpty ? null : await getGroupById(groupId);
    String? teamName;
    if (group != null && teamId.isNotEmpty) {
      teamName = (await getTeamById(groupId, teamId))?.name;
    }
    return {
      'groupId': groupId,
      'teamId': teamId,
      'used': data['used'] == true,
      'groupName': group?.name,
      'teamName': teamName,
    };
  }

  /// Self-join via a one-time code: bind/create the member, provision their
  /// wallet, add them to the team if it's a team code, then consume the code.
  Future<FamilyMembership> joinByCode({
    required String code,
    required String name,
    String? phone,
    required String authUid,
    String? email,
  }) async {
    final clean = code.trim().toUpperCase();
    if (clean.isEmpty) throw JoinFamilyException('اكتب كود الدعوة.');
    final inviteRef = _inviteCodes.doc(clean);
    final invite = (await inviteRef.get()).data();
    if (invite == null) throw JoinFamilyException('كود الدعوة غير صحيح.');
    if (invite['used'] == true) {
      throw JoinFamilyException('كود الدعوة مُستخدَم بالفعل. اطلب رابطًا جديدًا.');
    }
    final groupId = (invite['groupId'] ?? '').toString();
    final teamId = (invite['teamId'] ?? '').toString();
    final group = await getGroupById(groupId);
    if (group == null) {
      throw JoinFamilyException('لم أجد العائلة. اطلب رابط دعوة جديد.');
    }

    final normalizedPhone = (phone ?? '').trim().isEmpty
        ? ''
        : _authService.normalizePhone(phone!.trim());
    if (normalizedPhone.isEmpty) {
      throw JoinFamilyException(
          'اكتب رقم موبايلك للانضمام — يجب أن يطابق الرقم الذي سجّله القائد لك.');
    }

    // Match strictly by the assigned PHONE — that's the join key. We do NOT
    // fall back to this login's other memberships: someone who is already a
    // family member (e.g. the admin testing) opening a team invite must still
    // match the worker slot by phone, not their own family doc.
    final slot = await getMemberByPhone(groupId, normalizedPhone);

    if (teamId.isNotEmpty) {
      // Worker join: must match a worker the admin added to THIS team.
      if (slot == null || slot.teamId != teamId) {
        throw JoinFamilyException(
            'رقمك غير مسجّل كعامل في هذا الفريق. اطلب من القائد إضافتك أولًا.');
      }
    } else {
      // Family join: must match a family member the admin pre-registered.
      if (slot == null || slot.isWorker) {
        throw JoinFamilyException(
            'رقمك غير مسجّل في هذه العائلة. اطلب من القائد إضافتك أولًا.');
      }
    }

    final toSave = slot.copyWith(
      name: slot.name.trim().isEmpty ? name : slot.name,
      phone: normalizedPhone,
      authUid: authUid,
      email: email,
      phoneVerified: true,
    );
    await _members(groupId)
        .doc(toSave.id)
        .set(toSave.toMap(), SetOptions(merge: true));

    // Their wallet was created when the admin added them; ensure it exists.
    try {
      await provisionMemberWallets(groupId);
    } catch (_) {}

    await inviteRef.set({
      'used': true,
      'usedByUid': authUid,
      'usedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));

    return FamilyMembership(group: group, member: toSave);
  }

  Future<GroupModel?> getGroupByName(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return null;
    final q = await _families.where('name', isEqualTo: clean).limit(1).get();
    if (q.docs.isEmpty) return null;
    return GroupModel.fromMap(q.docs.first.data());
  }

  Future<GroupModel?> getGroupById(String groupId) async {
    final doc = await _families.doc(groupId).get();
    if (!doc.exists || doc.data() == null) return null;
    return GroupModel.fromMap(doc.data()!);
  }

  Future<List<FamilyMembership>> findMembershipsByPhone(String phone) async {
    final candidates = _phoneLookupCandidates(phone);
    if (candidates.isEmpty) return const [];
    final byGroup = <String, FamilyMembership>{};
    for (final candidate in candidates) {
      final q = await _fs
          .collectionGroup('members')
          .where('phone', isEqualTo: candidate)
          .limit(8)
          .get();
      for (final doc in q.docs) {
        final groupRef = doc.reference.parent.parent;
        if (groupRef == null || byGroup.containsKey(groupRef.id)) continue;
        final group = await getGroupById(groupRef.id);
        if (group == null) continue;
        byGroup[group.id] = FamilyMembership(
          group: group,
          member: UserModel.fromMap(doc.data()),
        );
      }
    }
    final items = byGroup.values.toList()
      ..sort((a, b) => a.group.name.compareTo(b.group.name));
    return items;
  }

  /// Bind EVERY member doc whose phone matches [phone] to [authUid] — with NO
  /// per-group dedup, so a login is reconnected to all of its slots at once,
  /// including a family admin whose authUid binding got tangled. Returns how
  /// many docs now point at [authUid].
  Future<int> rebindMembersByPhone(String phone, String authUid) async {
    final candidates = _phoneLookupCandidates(phone);
    if (candidates.isEmpty || authUid.trim().isEmpty) return 0;
    final seen = <String>{};
    var count = 0;
    for (final candidate in candidates) {
      final q = await _fs
          .collectionGroup('members')
          .where('phone', isEqualTo: candidate)
          .limit(30)
          .get();
      for (final doc in q.docs) {
        final groupRef = doc.reference.parent.parent;
        if (groupRef == null) continue;
        final key = '${groupRef.id}/${doc.id}';
        if (seen.contains(key)) continue;
        seen.add(key);
        final member = UserModel.fromMap(doc.data());
        if (member.authUid == authUid) {
          count++; // already bound to this login
          continue;
        }
        try {
          await bindMemberAuthUid(groupRef.id, member, authUid);
          count++;
        } catch (_) {
          // Skip a doc we couldn't write; keep rebinding the rest.
        }
      }
    }
    return count;
  }

  Future<List<TeamMembership>> findTeamMembershipsByPhone(String phone) async {
    final candidates = _phoneLookupCandidates(phone);
    if (candidates.isEmpty) return const [];
    final ids = candidates.map((p) => 'phone_$p').toSet();
    final byKey = <String, TeamMembership>{};
    for (final id in ids) {
      final q = await _fs
          .collectionGroup('teams')
          .where('memberIds', arrayContains: id)
          .limit(12)
          .get();
      for (final doc in q.docs) {
        final groupRef = doc.reference.parent.parent;
        if (groupRef == null) continue;
        final key = '${groupRef.id}/${doc.id}';
        if (byKey.containsKey(key)) continue;
        final group = await getGroupById(groupRef.id);
        if (group == null) continue;
        final team = TeamModel.fromMap({...doc.data(), 'id': doc.id});
        final member = UserModel(
          id: id,
          name: team.memberNames[id] ?? 'عضو فريق',
          phone: team.memberPhones[id],
          canAddExpenses: true,
          canManageMembers: false,
          canManageBudgets: false,
          phoneVerified: true,
        );
        byKey[key] = TeamMembership(group: group, team: team, member: member);
      }
    }
    final items = byKey.values.toList()
      ..sort((a, b) => a.team.name.compareTo(b.team.name));
    return items;
  }

  /// Point a family's admin pointer at [adminId]. Used by admin recovery so the
  /// family has a real admin again even if the original record was overwritten.
  Future<void> setGroupAdminId(String groupId, String adminId) async {
    await _families
        .doc(groupId)
        .set({'adminId': adminId}, SetOptions(merge: true));
  }

  Future<void> joinGroup(String groupId, UserModel user) async {
    final normalizedPhone =
        user.phone == null ? null : _authService.normalizePhone(user.phone!);
    final prepared = normalizedPhone == null || normalizedPhone.isEmpty
        ? null
        : await getMemberByPhone(groupId, normalizedPhone);
    final userToMerge = normalizedPhone == null || normalizedPhone.isEmpty
        ? user
        : user.copyWith(phone: normalizedPhone);
    final toSave = prepared == null
        ? userToMerge
        : prepared.copyWith(
            id: userToMerge.id,
            name: userToMerge.name.isEmpty ? prepared.name : userToMerge.name,
            phone: userToMerge.phone ?? prepared.phone,
            authUid: userToMerge.authUid ?? prepared.authUid,
            phoneVerified:
                userToMerge.phoneVerified || prepared.phoneVerified);
    await _members(groupId)
        .doc(toSave.id)
        .set(toSave.toMap(), SetOptions(merge: true));
    if (prepared != null && prepared.id != toSave.id) {
      await _members(groupId).doc(prepared.id).delete();
    }
  }

  Future<UserModel> bindMemberAuthUid(
      String groupId, UserModel member, String authUid) async {
    // This is only ever called after the phone has just been verified on this
    // device, so record the member as verified at the same time.
    final updated = member.copyWith(authUid: authUid, phoneVerified: true);
    await _members(groupId)
        .doc(member.id)
        .set(updated.toMap(), SetOptions(merge: true));
    final active = await getActiveUser();
    if (active?.id == member.id) {
      final group = await getGroupById(groupId) ?? await getActiveGroup();
      if (group != null) await saveActiveSession(updated, group);
    }
    return updated;
  }

  // ─── Members ───
  Future<List<UserModel>> getMembersSync(String groupId) async {
    final q = await _members(groupId).orderBy('createdAt').get();
    return q.docs.map((d) => UserModel.fromMap(d.data())).toList();
  }

  Future<UserModel?> getMember(String groupId, String userId) async {
    final doc = await _members(groupId).doc(userId).get();
    if (!doc.exists || doc.data() == null) return null;
    return UserModel.fromMap(doc.data()!);
  }

  Future<UserModel?> getMemberByPhone(String groupId, String phone) async {
    final candidates = _phoneLookupCandidates(phone);
    if (candidates.isEmpty) return null;
    for (final candidate in candidates) {
      final q = await _members(groupId)
          .where('phone', isEqualTo: candidate)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty) return UserModel.fromMap(q.docs.first.data());
    }
    return null;
  }

  List<String> _phoneLookupCandidates(String phone) {
    final raw = phone.trim();
    if (raw.isEmpty) return const [];
    final normalized = _authService.normalizePhone(raw);
    final compact = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    final candidates = <String>[
      normalized,
      raw,
      compact,
    ];
    if (normalized.startsWith('+20') && normalized.length > 3) {
      final withoutCountry = normalized.substring(3);
      candidates.add(withoutCountry);
      candidates.add('0$withoutCountry');
      candidates.add('20$withoutCountry');
      candidates.add('0020$withoutCountry');
    }
    return candidates.where((p) => p.trim().isNotEmpty).toSet().toList();
  }

  Future<void> updateMemberLimit(
      String groupId, String userId, double limit) async {
    await updateMember(
        groupId, userId, (member) => member.copyWith(monthlyLimit: limit));
  }

  Future<void> updateMemberPhoto(
      String groupId, String userId, String photoPath) async {
    await updateMember(
        groupId, userId, (member) => member.copyWith(photoUrl: photoPath));
  }

  /// Edit a person's display name and/or spending limit in place (no re-key).
  Future<void> updateMemberNameLimit(
    String groupId,
    String userId, {
    String? name,
    double? monthlyLimit,
  }) async {
    await updateMember(
      groupId,
      userId,
      (m) => m.copyWith(
        name: (name == null || name.trim().isEmpty) ? m.name : name.trim(),
        monthlyLimit: monthlyLimit ?? m.monthlyLimit,
      ),
    );
  }

  /// Change a PENDING member's phone — the join key. Re-keys the member doc to
  /// `phone_<newPhone>` and moves its references (wallet owner, family
  /// memberIds, and team membership for a worker). Refused once the record has
  /// joined (a real login is bound) so a live identity is never re-keyed.
  /// Returns an Arabic error, or null on success.
  Future<String?> changePendingMemberPhone(
      String groupId, UserModel member, String newPhoneRaw) async {
    if (member.joined) {
      return 'لا يمكن تغيير رقم الهاتف بعد انضمام الحساب — الرقم يصبح ثابتًا.';
    }
    final newPhone = _authService.normalizePhone(newPhoneRaw);
    if (newPhone.length < 8) return 'اكتب رقم موبايل صحيح.';
    final oldId = member.id;
    final newId = _authService.memberIdForPhone(newPhone);
    if (newId == oldId) return null; // unchanged
    final existingByPhone = await getMemberByPhone(groupId, newPhone);
    final existingDoc = await _members(groupId).doc(newId).get();
    if (existingByPhone != null || existingDoc.exists) {
      return 'هذا الرقم مستخدم بالفعل لحساب آخر في هذه العائلة.';
    }
    // 1) the re-keyed member doc.
    final moved = member.copyWith(id: newId, phone: newPhone);
    await _members(groupId).doc(newId).set(moved.toMap());
    // 2) move the member's wallet (looked up by ownerId, so just retag it).
    final wallets = await getWalletsSync(groupId);
    for (final w in wallets) {
      if (w.isMemberWallet && w.ownerId == oldId) {
        await _wallets(groupId)
            .doc(w.id)
            .set({'ownerId': newId}, SetOptions(merge: true));
      }
    }
    // 3) family memberIds list (best-effort).
    final famSnap = await _families.doc(groupId).get();
    final ids =
        List<String>.from((famSnap.data()?['memberIds'] ?? const []) as List);
    if (ids.contains(oldId)) {
      final newIds =
          ids.map((id) => id == oldId ? newId : id).toSet().toList();
      await _families
          .doc(groupId)
          .set({'memberIds': newIds}, SetOptions(merge: true));
    }
    // 4) a worker's team membership.
    final teamId = member.teamId;
    if (teamId != null && teamId.isNotEmpty) {
      final team = await getTeamById(groupId, teamId);
      if (team != null) {
        final tIds =
            team.memberIds.map((id) => id == oldId ? newId : id).toSet().toList();
        final names = Map<String, String>.from(team.memberNames);
        final phones = Map<String, String>.from(team.memberPhones);
        if (names.containsKey(oldId)) names[newId] = names.remove(oldId)!;
        phones.remove(oldId);
        phones[newId] = newPhone;
        await _teams(groupId).doc(teamId).set({
          'memberIds': tIds,
          'memberNames': names,
          'memberPhones': phones,
        }, SetOptions(merge: true));
      }
    }
    // 5) remove the old record.
    await _members(groupId).doc(oldId).delete();
    return null;
  }

  /// Change a JOINED worker's (or member's) phone — their real identity key.
  /// Unlike changePendingMemberPhone (which refuses once joined), this
  /// migrates every structural foreign key pointing at the old member id: the
  /// member doc itself, their wallet, the family's memberIds list, their
  /// team's memberIds/memberNames/memberPhones, every TransactionModel.userId,
  /// every FamilyNotificationModel.targetUserIds entry, and every team-chat
  /// message's senderId under their team. Historical descriptive snapshots
  /// (TransactionModel.userName, WalletEntryModel.byName/byPhone,
  /// ChatMessage.senderName) are left untouched — same precedent as
  /// updateMemberNameLimit never rewriting old snapshots.
  ///
  /// Best-effort, not atomic (Firestore cannot transact across an unbounded
  /// document set) — matches changePendingMemberPhone's own risk tolerance.
  /// Operations are ordered so a partial failure leaves the OLD identity
  /// fully functional: the new member doc is created FIRST (so both ids
  /// resolve to "this person" during the migration window — login stays
  /// unambiguous since it resolves via authUid, not this doc id), the
  /// expensive paginated rewrites happen NEXT, and the OLD member doc is
  /// deleted LAST, only once every other step has succeeded. A re-run after a
  /// partial failure is safe: the "where field == oldId"-style queries only
  /// ever return still-unmigrated docs.
  Future<String?> changeJoinedMemberPhone(
      String groupId, UserModel member, String newPhoneRaw) async {
    final newPhone = _authService.normalizePhone(newPhoneRaw);
    if (newPhone.length < 8) return 'اكتب رقم موبايل صحيح.';
    final oldId = member.id;
    final newId = _authService.memberIdForPhone(newPhone);
    if (newId == oldId) return null; // unchanged
    final existingByPhone = await getMemberByPhone(groupId, newPhone);
    final existingDoc = await _members(groupId).doc(newId).get();
    if (existingByPhone != null || existingDoc.exists) {
      return 'هذا الرقم مستخدم بالفعل لحساب آخر في هذه العائلة.';
    }

    // 1) Create the NEW member doc first — carries authUid forward unchanged,
    // so login (which resolves by authUid, not this id) stays unambiguous.
    final moved = member.copyWith(id: newId, phone: newPhone);
    await _members(groupId).doc(newId).set(moved.toMap());

    // 2) Move the wallet (looked up by ownerId).
    final wallets = await getWalletsSync(groupId);
    for (final w in wallets) {
      if (w.isMemberWallet && w.ownerId == oldId) {
        await _wallets(groupId)
            .doc(w.id)
            .set({'ownerId': newId}, SetOptions(merge: true));
      }
    }

    // 3) Family memberIds list.
    final famSnap = await _families.doc(groupId).get();
    final ids =
        List<String>.from((famSnap.data()?['memberIds'] ?? const []) as List);
    if (ids.contains(oldId)) {
      final newIds =
          ids.map((id) => id == oldId ? newId : id).toSet().toList();
      await _families
          .doc(groupId)
          .set({'memberIds': newIds}, SetOptions(merge: true));
    }

    // 4) Team membership + (7) that team's chat message senderIds.
    final teamId = member.teamId;
    if (teamId != null && teamId.isNotEmpty) {
      final team = await getTeamById(groupId, teamId);
      if (team != null) {
        final tIds = team.memberIds
            .map((id) => id == oldId ? newId : id)
            .toSet()
            .toList();
        final names = Map<String, String>.from(team.memberNames);
        final phones = Map<String, String>.from(team.memberPhones);
        if (names.containsKey(oldId)) names[newId] = names.remove(oldId)!;
        phones.remove(oldId);
        phones[newId] = newPhone;
        await _teams(groupId).doc(teamId).set({
          'memberIds': tIds,
          'memberNames': names,
          'memberPhones': phones,
        }, SetOptions(merge: true));
      }
      await _updateCollectionWhere(
        _teamMessages(groupId, teamId).where('senderId', isEqualTo: oldId),
        (_) => {'senderId': newId},
      );
    }

    // 5) Every transaction's userId (paginated — a worker/member may have many).
    await _updateCollectionWhere(
      _transactions(groupId).where('userId', isEqualTo: oldId),
      (_) => {'userId': newId},
    );

    // 6) Every notification's targetUserIds array — read-modify-write since
    // both the add and the remove target the same field.
    await _updateCollectionWhere(
      _notifications(groupId).where('targetUserIds', arrayContains: oldId),
      (data) {
        final targets =
            List<String>.from((data['targetUserIds'] ?? const []) as List);
        return {
          'targetUserIds':
              targets.map((id) => id == oldId ? newId : id).toList(),
        };
      },
    );

    // 7b) Move the profile photo — avatars are keyed by member id
    // (avatars/{memberId}), so without this the person silently loses
    // their photo after a phone change.
    final avatarSnap = await _avatars(groupId).doc(oldId).get();
    final avatarData = avatarSnap.data();
    if (avatarSnap.exists && avatarData != null) {
      await _avatars(groupId).doc(newId).set(avatarData);
      await _avatars(groupId).doc(oldId).delete();
    }

    // 8) Delete the OLD member doc LAST — only reached once every step above
    // has succeeded without throwing.
    await _members(groupId).doc(oldId).delete();
    return null;
  }

  Future<void> updateMemberPermissions(
    String groupId,
    String userId, {
    bool? canAddExpenses,
    bool? canManageMembers,
    bool? canManageBudgets,
  }) async {
    await updateMember(
      groupId,
      userId,
      (member) => member.copyWith(
        canAddExpenses: canAddExpenses,
        canManageMembers: canManageMembers,
        canManageBudgets: canManageBudgets,
      ),
    );
  }

  Future<void> updateMember(
    String groupId,
    String userId,
    UserModel Function(UserModel member) update,
  ) async {
    final current = await getMember(groupId, userId);
    if (current == null) return;
    final updated = update(current);
    await _members(groupId)
        .doc(userId)
        .set(updated.toMap(), SetOptions(merge: true));
    final active = await getActiveUser();
    if (active?.id == userId) {
      final group = await getGroupById(groupId) ?? await getActiveGroup();
      if (group != null) await saveActiveSession(updated, group);
    }
  }

  Future<double> getMemberMonthlySpending(String groupId, String userId) async {
    final now = DateTime.now();
    // Scoped to one userId already, so a worker's own team expenses can't
    // double-count anything here — include them, or a worker's currentSpending
    // (and their monthly-cap warning) silently never reflects team spend.
    final txns = await getTransactionsSync(groupId, includeTeamExpenses: true);
    return txns.where((t) {
      return t.userId == userId &&
          t.isExpense &&
          t.date.year == now.year &&
          t.date.month == now.month;
    }).fold<double>(0.0, (sum, t) => sum + t.amount);
  }

  // ─── Teams ───
  Future<List<TeamModel>> getTeamsSync(String groupId) async {
    final q = await _teams(groupId).orderBy('createdAt').get();
    return q.docs.map((d) {
      final data = d.data();
      return TeamModel.fromMap({...data, 'id': data['id'] ?? d.id});
    }).toList();
  }

  Future<List<TeamModel>> getVisibleTeams(
    String groupId,
    UserModel user,
  ) async {
    final teams = await getTeamsSync(groupId);
    if (user.isAdmin || user.canManageMembers || user.canManageBudgets) {
      return teams;
    }
    return teams
        .where((team) => team.ownerId == user.id || team.hasMember(user.id))
        .toList();
  }

  Future<TeamModel?> getTeamById(String groupId, String teamId) async {
    if (teamId.trim().isEmpty) return null;
    final doc = await _teams(groupId).doc(teamId).get();
    if (!doc.exists || doc.data() == null) return null;
    final data = doc.data()!;
    return TeamModel.fromMap({...data, 'id': data['id'] ?? doc.id});
  }

  Future<TeamModel> addTeam(
    String groupId, {
    required String name,
    required UserModel owner,
    List<UserModel> members = const [],
  }) async {
    final clean = name.trim().isEmpty ? 'فريق جديد' : name.trim();
    final id = '${DateTime.now().millisecondsSinceEpoch}_${_docSafeId(clean)}';
    final selected = <String, UserModel>{
      owner.id: owner,
      for (final member in members) member.id: member,
    };
    final now = DateTime.now();
    final team = TeamModel(
      id: id,
      groupId: groupId,
      name: clean,
      ownerId: owner.id,
      ownerName: owner.name,
      memberIds: selected.keys.toList(),
      memberNames: selected.map((id, member) => MapEntry(id, member.name)),
      memberPhones: selected.map((id, member) => MapEntry(
            id,
            member.phone ?? '',
          )),
      createdAt: now,
      updatedAt: now,
    );
    await _teams(groupId).doc(id).set(team.toMap(), SetOptions(merge: true));
    return team;
  }

  Future<void> updateTeam(
    String groupId,
    TeamModel team, {
    String? name,
    List<UserModel>? members,
  }) async {
    final selected = members == null
        ? null
        : <String, UserModel>{
            for (final member in members) member.id: member,
          };
    final externalIds = selected == null
        ? const <String>[]
        : team.memberIds
            .where((id) => !selected.containsKey(id) && id != team.ownerId)
            .toList();
    final mergedNames = selected == null
        ? null
        : <String, String>{
            for (final entry in selected.entries) entry.key: entry.value.name,
            for (final id in externalIds)
              id: team.memberNames[id] ?? 'عضو فريق',
          };
    final mergedPhones = selected == null
        ? null
        : <String, String>{
            for (final entry in selected.entries)
              entry.key: entry.value.phone ?? '',
            for (final id in externalIds) id: team.memberPhones[id] ?? '',
          };
    await _teams(groupId).doc(team.id).set({
      if (name != null) 'name': name.trim().isEmpty ? team.name : name.trim(),
      if (selected != null)
        'memberIds': {...selected.keys, ...externalIds}.toList(),
      if (mergedNames != null) 'memberNames': mergedNames,
      if (mergedPhones != null) 'memberPhones': mergedPhones,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  /// Remove a worker from a team and delete their worker record + archive
  /// their wallet (workers belong to the team, not the family). Refuses while
  /// the wallet still holds money — same rule as deleteWallet — so a removal
  /// can never strand a balance inside an archived wallet. Returns an Arabic
  /// error, or null on success.
  Future<String?> removeWorker(
      String groupId, TeamModel team, String workerId) async {
    // The wallet is found by ownerId, never by recomputing the doc id: a
    // phone re-key repoints ownerId but the wallet doc keeps its original
    // id forever, so mem_<currentMemberId> may not exist.
    final wallet = await _memberWalletOf(groupId, workerId);
    if (wallet != null && wallet.balance.abs() > 0.005) {
      return 'محفظة العامل بها رصيد ${formatMoney(wallet.balance)} ج — '
          'اسحبه أولًا ثم أعد المحاولة.';
    }
    await removeTeamMember(groupId, team, workerId);
    await _members(groupId).doc(workerId).delete();
    if (wallet != null) await _archiveWallet(groupId, wallet.id);
    return null;
  }

  /// Remove a family member: same semantics as removing a worker — refuse
  /// while their wallet holds money, then delete the member doc, archive the
  /// wallet (found by ownerId), and drop the stale id from the family doc's
  /// memberIds list. Returns an Arabic error, or null on success.
  Future<String?> removeFamilyMember(String groupId, String userId) async {
    final wallet = await _memberWalletOf(groupId, userId);
    if (wallet != null && wallet.balance.abs() > 0.005) {
      return 'محفظة العضو بها رصيد ${formatMoney(wallet.balance)} ج — '
          'اسحبه أولًا ثم أعد المحاولة.';
    }
    await _members(groupId).doc(userId).delete();
    if (wallet != null) await _archiveWallet(groupId, wallet.id);
    final famSnap = await _families.doc(groupId).get();
    final ids =
        List<String>.from((famSnap.data()?['memberIds'] ?? const []) as List);
    if (ids.contains(userId)) {
      await _families.doc(groupId).set(
          {'memberIds': ids.where((id) => id != userId).toList()},
          SetOptions(merge: true));
    }
    return null;
  }

  Future<WalletModel?> _memberWalletOf(String groupId, String memberId) async {
    final wallets = await getWalletsSync(groupId);
    for (final w in wallets) {
      if (w.isMemberWallet && w.ownerId == memberId) return w;
    }
    return null;
  }

  Future<void> _archiveWallet(String groupId, String walletId) async {
    await _wallets(groupId).doc(walletId).set({
      'archived': true,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  Future<void> removeTeamMember(
      String groupId, TeamModel team, String userId) async {
    final ids = team.memberIds.where((id) => id != userId).toList();
    final names = Map<String, String>.from(team.memberNames)..remove(userId);
    final phones = Map<String, String>.from(team.memberPhones)..remove(userId);
    await _teams(groupId).doc(team.id).set({
      'memberIds': ids,
      'memberNames': names,
      'memberPhones': phones,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  Future<void> addTeamMember(
      String groupId, String teamId, UserModel member) async {
    final team = await getTeamById(groupId, teamId);
    if (team == null) return;
    final ids = <String>{...team.memberIds, member.id}.toList();
    final names = Map<String, String>.from(team.memberNames)
      ..[member.id] = member.name;
    final phones = Map<String, String>.from(team.memberPhones);
    if ((member.phone ?? '').trim().isNotEmpty) {
      phones[member.id] = member.phone!.trim();
    }
    await _teams(groupId).doc(teamId).set({
      'memberIds': ids,
      'memberNames': names,
      'memberPhones': phones,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  /// Deleting a team deletes its expenses THROUGH deleteTransaction (refund +
  /// atomic delete per expense), never by batch-deleting the raw docs — the
  /// old batch delete left the workers' wallets debited with orphaned ledger
  /// entries, which the reconcile self-heal then faithfully resurrected as
  /// new transactions, making team deletion silently undo itself.
  Future<void> deleteTeam(String groupId, String teamId,
      {String? byName, String? byPhone}) async {
    final txns = await getTeamTransactions(groupId, teamId);
    for (final txn in txns) {
      await deleteTransaction(groupId, txn.id, byName: byName, byPhone: byPhone);
    }
    await _teams(groupId).doc(teamId).delete();
  }

  Future<List<TransactionModel>> getTeamTransactions(
    String groupId,
    String teamId,
  ) async {
    final q = await _transactions(groupId)
        .where('teamId', isEqualTo: teamId)
        .limit(500)
        .get();
    final txns = q.docs.map((d) => TransactionModel.fromMap(d.data())).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return txns;
  }

  double spentForTeam(List<TransactionModel> txns) {
    return txns
        .where((t) => t.isExpense)
        .fold<double>(0.0, (sum, t) => sum + t.amount);
  }

  /// One-time repair for a worker whose wallet ledger shows expense history
  /// that never shows up in any transactions-based view (تقاريري, this
  /// screen's own list, the admin's team ledger). Two distinct faults, fixed
  /// together:
  ///
  /// 1) A transaction whose `walletId` matches this worker's wallet but whose
  ///    `teamId`/`userId` are stale (from before a re-key, or from before the
  ///    team-expense flow stamped `teamId` on every write) — re-tag it. The
  ///    wallet's own id never changes even when its `ownerId` is repointed by
  ///    changeJoinedMemberPhone, so `walletId` is the one link that can't drift.
  ///
  /// 2) A wallet-ledger entry with `source == 'expense'` whose `refTransactionId`
  ///    points at NO existing transaction document — meaning the transaction
  ///    was never written at all (an older/incomplete code path once posted
  ///    the ledger debit without also calling addTransaction). Nothing to
  ///    re-tag here; the record has to be reconstructed from the ledger entry
  ///    itself (amount, date, and the category encoded in its note as
  ///    "<raw text> — <category>", the fixed shape buildExpenseDescription
  ///    always writes).
  ///
  /// Runs automatically from every refresh action (worker's own page, admin's
  /// team page, the wallets overview) instead of needing a manual admin
  /// button — it's purely additive (creates or re-tags, never deletes or
  /// changes an amount), so it's safe to run every time. Returns how many
  /// transactions were created or re-tagged.
  Future<int> reconcileMemberWallet(
      String groupId, UserModel owner, WalletModel wallet) async {
    if (!wallet.isMemberWallet || wallet.ownerId != owner.id) return 0;
    String? teamId;
    String? teamName;
    if (owner.isWorker) {
      teamId = owner.teamId;
      teamName = (await getTeamById(groupId, teamId!))?.name;
    }

    final all = await getTransactionsSync(groupId, includeTeamExpenses: true);
    final byId = {for (final t in all) t.id: t};
    var fixed = 0;

    // 1) Re-tag transactions that exist but drifted from this wallet's
    // current owner/team (e.g. from before a re-key).
    for (final t in all) {
      if (t.walletId != wallet.id) continue;
      final needsUserFix = t.userId != owner.id;
      final needsTeamFix = teamId != null && t.teamId != teamId;
      if (!needsUserFix && !needsTeamFix) continue;
      final update = <String, dynamic>{};
      if (needsUserFix) {
        update['userId'] = owner.id;
        update['userName'] = owner.name;
      }
      if (needsTeamFix) {
        update['teamId'] = teamId;
        update['teamName'] = teamName;
      }
      await _transactions(groupId)
          .doc(t.id)
          .set(update, SetOptions(merge: true));
      fixed++;
    }

    // 2) Backfill expense ledger entries with no transaction behind them.
    final entries = await getWalletEntriesSync(groupId, wallet.id);
    for (final e in entries) {
      if (e.source != 'expense') continue;
      final existingId = e.refTransactionId;
      if (existingId != null && byId.containsKey(existingId)) continue;
      final note = (e.note ?? '').trim();
      final parts = note.split(' — ');
      final category = parts.length > 1 ? parts.last.trim() : 'غير مصنف';
      final rawText = parts.length > 1
          ? parts.sublist(0, parts.length - 1).join(' — ').trim()
          : note;
      final id = existingId ?? _uuid.v4();
      await addTransaction(TransactionModel(
        id: id,
        groupId: groupId,
        userId: owner.id,
        userName: owner.name,
        amount: e.amount,
        category: category,
        isExpense: true,
        note: rawText.isEmpty ? null : rawText,
        date: e.at,
        walletId: wallet.id,
        walletName: wallet.name,
        teamId: teamId,
        teamName: teamName,
        description: note.isEmpty ? category : note,
      ));
      fixed++;
    }
    return fixed;
  }

  /// Reconciles every family member's AND every worker's own wallet in one
  /// pass — for admin-facing refresh actions that need to self-heal
  /// everyone's reports at once (the family wallets overview, the teams
  /// page), not just one person's own.
  Future<int> reconcileAllMemberWallets(String groupId) async {
    final members = await getMembersSync(groupId);
    final wallets = await getWalletsSync(groupId);
    var fixed = 0;
    for (final m in members) {
      WalletModel? wallet;
      for (final w in wallets) {
        if (w.isMemberWallet && w.ownerId == m.id) {
          wallet = w;
          break;
        }
      }
      if (wallet == null) continue;
      fixed += await reconcileMemberWallet(groupId, m, wallet);
    }
    return fixed;
  }

  // ─── Messages ───
  Future<List<ChatMessage>> getMessagesSync(String groupId) async {
    final q = await _messages(groupId)
        .orderBy('timestamp', descending: true)
        .limit(200)
        .get();
    return q.docs.map((d) => ChatMessage.fromMap(d.data())).toList();
  }

  Stream<List<ChatMessage>> watchMessages(String groupId) {
    return _messages(groupId)
        .orderBy('timestamp', descending: true)
        .limit(200)
        .snapshots()
        .map((q) => q.docs.map((d) => ChatMessage.fromMap(d.data())).toList());
  }

  Future<void> sendMessage(ChatMessage message) async {
    await _messages(message.groupId).doc(message.id).set(message.toMap());
  }

  Future<void> markTransactionMessageDeleted(
      String groupId, String transactionId) async {
    final q = await _messages(groupId)
        .where('transactionId', isEqualTo: transactionId)
        .limit(1)
        .get();
    if (q.docs.isEmpty) return;
    final data = q.docs.first.data();
    final amount = (data['amount'] as num?)?.toDouble() ?? 0;
    final category = (data['category'] ?? '').toString();
    await q.docs.first.reference.update({
      'isDeleted': true,
      'content':
          'تم حذف هذا الإدخال وإرجاع ${formatMoney(amount)} ج من $category إلى الميزانية',
    });
  }

  Future<void> clearMessages(String groupId) async {
    await _deleteQuerySnapshot(await _messages(groupId).limit(500).get());
  }

  // ─── Team chat ───
  // Mirrors the flat family chat methods above exactly, just scoped under
  // families/{groupId}/teams/{teamId}/messages instead of families/{groupId}/messages.
  Future<List<ChatMessage>> getTeamChatMessagesSync(
      String groupId, String teamId) async {
    final q = await _teamMessages(groupId, teamId)
        .orderBy('timestamp', descending: true)
        .limit(200)
        .get();
    return q.docs.map((d) => ChatMessage.fromMap(d.data())).toList();
  }

  Stream<List<ChatMessage>> watchTeamChatMessages(
      String groupId, String teamId) {
    return _teamMessages(groupId, teamId)
        .orderBy('timestamp', descending: true)
        .limit(200)
        .snapshots()
        .map((q) => q.docs.map((d) => ChatMessage.fromMap(d.data())).toList());
  }

  Future<void> sendTeamChatMessage(
      String groupId, String teamId, ChatMessage message) async {
    await _teamMessages(groupId, teamId).doc(message.id).set(message.toMap());
  }

  Future<void> clearTeamChatMessages(String groupId, String teamId) async {
    await _deleteQuerySnapshot(
        await _teamMessages(groupId, teamId).limit(500).get());
  }

  // ─── Transactions ───
  Future<List<TransactionModel>> getTransactionsSync(
    String groupId, {
    bool includeTeamExpenses = false,
  }) async {
    final q = await _transactions(groupId)
        .orderBy('date', descending: true)
        .limit(1000)
        .get();
    final txns = q.docs.map((d) => TransactionModel.fromMap(d.data())).toList();
    if (includeTeamExpenses) return txns;
    return txns.where((t) => !t.isTeamExpense).toList();
  }

  Future<void> addTransaction(TransactionModel transaction) async {
    await _transactions(transaction.groupId)
        .doc(transaction.id)
        .set(transaction.toMap());
    if (transaction.isExpense) {
      try {
        final currentSpend = await getMemberMonthlySpending(
            transaction.groupId, transaction.userId);
        await updateMember(
          transaction.groupId,
          transaction.userId,
          (member) => member.copyWith(currentSpending: currentSpend),
        );
        await recalculateBudgetsForCurrentMonth(transaction.groupId);
      } catch (_) {
        // The transaction itself is already queued locally by Firestore.
        // Totals will refresh from streams/cache when the device reconnects.
      }
    }
  }

  /// The ONE path for recording an expense that also draws from a wallet.
  /// Every "an expense happened" caller (family, team) must use this instead
  /// of chaining addTransaction + applyWalletDelta as two separate network
  /// calls — that pattern is exactly how old data ended up with a wallet
  /// ledger entry and NO transaction document behind it (one call succeeded,
  /// the other didn't, or an earlier version of this code only ever made
  /// one of the two calls). Here both writes ride the same Firestore
  /// transaction as the wallet balance update: either the transaction
  /// document and its wallet effect both land, or neither does.
  Future<void> recordTransaction(
    TransactionModel transaction, {
    WalletModel? wallet,
    String? byName,
    String? byPhone,
  }) async {
    final txnRef = _transactions(transaction.groupId).doc(transaction.id);
    if (wallet == null || !transaction.isExpense) {
      await txnRef.set(transaction.toMap());
    } else {
      await applyWalletDelta(
        transaction.groupId,
        wallet.id,
        -transaction.amount,
        source: 'expense',
        note: transaction.description ?? transaction.category,
        refTransactionId: transaction.id,
        byName: byName,
        byPhone: byPhone,
        alsoWrite: (tx) => tx.set(txnRef, transaction.toMap()),
      );
    }
    if (transaction.isExpense) {
      try {
        final currentSpend = await getMemberMonthlySpending(
            transaction.groupId, transaction.userId);
        await updateMember(
          transaction.groupId,
          transaction.userId,
          (member) => member.copyWith(currentSpending: currentSpend),
        );
        await recalculateBudgetsForCurrentMonth(transaction.groupId);
      } catch (_) {
        // The transaction + wallet effect are already committed atomically
        // above. Totals will refresh from streams/cache when reconnected.
      }
    }
  }

  /// Delete a transaction AND undo its effect on the ledger, atomically — the
  /// document delete rides the SAME Firestore transaction as the reversing
  /// wallet entry, so a delete can never succeed while its reversal fails (or
  /// vice versa), which would otherwise silently make money vanish or
  /// double-count. For an expense this posts a reversing entry (+amount) back
  /// into the wallet it was charged to, then refreshes the member's monthly
  /// spending and the budgets.
  Future<TransactionModel?> deleteTransaction(
      String groupId, String transactionId,
      {String? byName, String? byPhone}) async {
    final ref = _transactions(groupId).doc(transactionId);
    final doc = await ref.get();
    if (!doc.exists || doc.data() == null) return null;
    final deleted = TransactionModel.fromMap(doc.data()!);
    if (deleted.isExpense && (deleted.walletId ?? '').isNotEmpty) {
      await applyWalletDelta(
        groupId,
        deleted.walletId!,
        deleted.amount, // + : put the spent money back into the wallet
        source: 'reversal',
        note: 'إرجاع: ${deleted.category}',
        refTransactionId: deleted.id,
        byName: byName,
        byPhone: byPhone,
        alsoWrite: (tx) => tx.delete(ref),
      );
    } else {
      await ref.delete();
    }
    if (deleted.isExpense) {
      final currentSpend =
          await getMemberMonthlySpending(groupId, deleted.userId);
      await updateMember(
        groupId,
        deleted.userId,
        (member) => member.copyWith(currentSpending: currentSpend),
      );
      await recalculateBudgetsForCurrentMonth(groupId);
    }
    return deleted;
  }

  // ─── Wallets ───
  CollectionReference<Map<String, dynamic>> _walletEntries(
          String groupId, String walletId) =>
      _wallets(groupId).doc(walletId).collection('entries');

  Future<List<WalletModel>> getWalletsSync(String groupId) async {
    final q = await _wallets(groupId).get();
    final defaultRef = _wallets(groupId).doc('default');
    final hasDefault = q.docs.any((doc) => doc.id == 'default');
    if (!hasDefault) {
      final now = DateTime.now().toIso8601String();
      await defaultRef.set({
        'id': 'default',
        'name': 'الحساب المنزلي الأساسي',
        'balance': 0,
        'isDefault': true,
        'createdAt': now,
        'updatedAt': now,
      }, SetOptions(merge: true));
    }

    final latest = await _wallets(groupId).get();
    final wallets = latest.docs
        .map((d) {
          final data = d.data();
          return WalletModel.fromMap({
            ...data,
            'id': (data['id'] ?? d.id).toString(),
            'name': (data['name'] ?? d.id).toString(),
          });
        })
        .where((w) => !w.archived)
        .toList();
    wallets.sort((a, b) {
      if (a.isDefault && !b.isDefault) return -1;
      if (!a.isDefault && b.isDefault) return 1;
      return a.name.compareTo(b.name);
    });
    return wallets;
  }

  /// Ensure every non-admin member owns exactly one wallet. Idempotent.
  Future<void> provisionMemberWallets(String groupId) async {
    final members = await getMembersSync(groupId);
    final snap = await _wallets(groupId).get();
    final ownerIds = <String>{};
    for (final d in snap.docs) {
      final data = d.data();
      if ((data['ownerType'] ?? '') == 'member') {
        final oid = (data['ownerId'] ?? '').toString();
        if (oid.isNotEmpty) ownerIds.add(oid);
      }
    }
    final now = DateTime.now().toIso8601String();
    for (final m in members) {
      if (m.isAdmin || m.id.isEmpty || ownerIds.contains(m.id)) continue;
      final id = 'mem_${_docSafeId(m.id)}';
      await _wallets(groupId).doc(id).set({
        'id': id,
        'name': m.name.isEmpty ? 'محفظة عضو' : m.name,
        'description': 'محفظة ${m.name}',
        'balance': 0,
        'isDefault': false,
        'archived': false,
        'ownerType': 'member',
        'ownerId': m.id,
        // Tag worker wallets so family views can exclude them.
        'teamId': m.teamId ?? '',
        'ledgerStarted': false,
        'createdAt': now,
        'updatedAt': now,
      }, SetOptions(merge: true));
    }
  }

  /// Family-only members (excludes workers). Use in family lists/reports.
  Future<List<UserModel>> getFamilyMembersSync(String groupId) async {
    final all = await getMembersSync(groupId);
    return all.where((m) => !m.isWorker).toList();
  }

  /// Workers belonging to a team (their own member docs, not family members).
  Future<List<UserModel>> getTeamWorkers(String groupId, String teamId) async {
    final all = await getMembersSync(groupId);
    return all.where((m) => m.teamId == teamId).toList();
  }

  /// Admin adds a worker to a team (NOT a family member). Creates the worker's
  /// member doc (teamId-tagged), provisions their wallet, links them to the team.
  Future<UserModel> addWorker(
    String groupId,
    String teamId, {
    required String name,
    required String phone,
  }) async {
    // Phone is the join key — a worker matches their slot by phone, like family.
    final normalizedPhone = _authService.normalizePhone(phone.trim());
    final id = _authService.memberIdForPhone(normalizedPhone);
    final worker = UserModel(
      id: id,
      name: name.trim().isEmpty ? 'عامل' : name.trim(),
      phone: normalizedPhone.isEmpty ? null : normalizedPhone,
      teamId: teamId,
      canAddExpenses: true,
      canManageMembers: false,
      canManageBudgets: false,
    );
    await _members(groupId).doc(worker.id).set({
      ...worker.toMap(),
      'createdAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
    await provisionMemberWallets(groupId);
    await addTeamMember(groupId, teamId, worker);
    return worker;
  }

  /// Move [amount] between two wallets (admin funding/withdrawal): CR the
  /// source, DR the destination, atomically in ONE Firestore transaction —
  /// either both sides move together or neither does. Two sequential
  /// postWalletEntry calls could leave money debited from the source with
  /// the destination credit never landing (a dropped connection between the
  /// two calls), which is the same class of partial-write bug as an expense
  /// with no transaction record. Returns an Arabic error, or null on success.
  Future<String?> transferBetweenWallets(
    String groupId, {
    required String fromWalletId,
    required String toWalletId,
    required double amount,
    String? byName,
    String? byPhone,
  }) async {
    if (amount <= 0) return 'المبلغ غير صحيح.';
    if (fromWalletId == toWalletId) return 'لا يمكن التحويل لنفس المحفظة.';
    final fromRef = _wallets(groupId).doc(fromWalletId);
    final toRef = _wallets(groupId).doc(toWalletId);
    final fromEntriesRef = fromRef.collection('entries');
    final toEntriesRef = toRef.collection('entries');

    return _fs.runTransaction<String?>((tx) async {
      final fromSnap = await tx.get(fromRef);
      final toSnap = await tx.get(toRef);
      if (!fromSnap.exists || !toSnap.exists) return 'المحفظة غير موجودة.';
      final fromData = fromSnap.data() ?? <String, dynamic>{};
      final toData = toSnap.data() ?? <String, dynamic>{};
      final fromBal = (fromData['balance'] as num?)?.toDouble() ?? 0;
      final toBal = (toData['balance'] as num?)?.toDouble() ?? 0;
      final fromName = (fromData['name'] ?? 'المحفظة').toString();
      final toName = (toData['name'] ?? 'المحفظة').toString();
      if (amount > fromBal + 0.005) {
        return 'الرصيد غير كافٍ في $fromName.';
      }

      final nowIso = DateTime.now().toIso8601String();
      final newFromBal = fromBal - amount;
      final newToBal = toBal + amount;

      final fromEntryRef = fromEntriesRef.doc();
      tx.set(fromEntryRef, {
        'id': fromEntryRef.id,
        'walletId': fromWalletId,
        'direction': 'CR',
        'amount': amount,
        'balanceAfter': newFromBal,
        'at': nowIso,
        'source': 'transfer',
        'note': 'تحويل إلى $toName',
        'byName': byName,
        'byPhone': byPhone,
      });
      tx.set(fromRef, {
        'balance': newFromBal,
        'updatedAt': nowIso,
        'updatedByName': byName,
        'updatedByPhone': byPhone,
        'ledgerStarted': true,
      }, SetOptions(merge: true));

      final toEntryRef = toEntriesRef.doc();
      tx.set(toEntryRef, {
        'id': toEntryRef.id,
        'walletId': toWalletId,
        'direction': 'DR',
        'amount': amount,
        'balanceAfter': newToBal,
        'at': nowIso,
        'source': 'transfer',
        'note': 'تحويل من $fromName',
        'byName': byName,
        'byPhone': byPhone,
      });
      tx.set(toRef, {
        'balance': newToBal,
        'updatedAt': nowIso,
        'updatedByName': byName,
        'updatedByPhone': byPhone,
        'ledgerStarted': true,
      }, SetOptions(merge: true));

      return null;
    });
  }

  /// Create a wallet. If [balance] is non-zero it is recorded as an opening
  /// ledger entry so the child table reconciles from day one.
  Future<void> addWallet(
    String groupId,
    String name, {
    String description = '',
    double balance = 0,
    String ownerType = 'admin',
    String? ownerId,
    String? byName,
    String? byPhone,
  }) async {
    final clean = name.trim().isEmpty ? 'محفظة جديدة' : name.trim();
    final id = _docSafeId(clean);
    final now = DateTime.now().toIso8601String();
    await _wallets(groupId).doc(id).set({
      'id': id,
      'name': clean,
      'description': description.trim(),
      'balance': 0,
      'isDefault': false,
      'archived': false,
      'ownerType': ownerType,
      'ownerId': ownerId,
      'ledgerStarted': false,
      'createdAt': now,
      'updatedAt': now,
      'updatedByName': byName,
      'updatedByPhone': byPhone,
    }, SetOptions(merge: true));
    if (balance != 0) {
      await postWalletEntry(
        groupId,
        id,
        direction: balance >= 0 ? 'DR' : 'CR',
        amount: balance.abs(),
        source: 'opening',
        note: 'رصيد افتتاحي',
        byName: byName,
        byPhone: byPhone,
      );
    }
  }

  /// Rename / re-describe / set the guide limit. Never touches balance; the id
  /// stays stable.
  Future<void> updateWallet(
    String groupId,
    String walletId, {
    String? name,
    String? description,
    double? limit,
    String? byName,
    String? byPhone,
  }) async {
    final m = <String, dynamic>{
      'updatedAt': DateTime.now().toIso8601String(),
      'updatedByName': byName,
      'updatedByPhone': byPhone,
    };
    if (name != null && name.trim().isNotEmpty) m['name'] = name.trim();
    if (description != null) m['description'] = description.trim();
    if (limit != null && limit >= 0) m['limit'] = limit;
    await _wallets(groupId).doc(walletId).set(m, SetOptions(merge: true));
  }

  /// Archive a wallet (only when empty; the default wallet can't be removed).
  /// Returns an Arabic error string, or null on success. The ledger is kept.
  Future<String?> deleteWallet(String groupId, String walletId) async {
    final ref = _wallets(groupId).doc(walletId);
    final snap = await ref.get();
    if (!snap.exists) return 'المحفظة غير موجودة.';
    final data = snap.data()!;
    if (data['isDefault'] == true) return 'لا يمكن حذف المحفظة الأساسية.';
    final bal = (data['balance'] as num?)?.toDouble() ?? 0;
    if (bal.abs() > 0.005) {
      return 'لا يمكن حذف محفظة بها رصيد. اسحب رصيدها أولًا.';
    }
    await ref.set({
      'archived': true,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
    return null;
  }

  /// Post a DR/CR of a fixed [amount] to the wallet ledger and update the
  /// parent balance atomically. Returns the new accumulated balance.
  Future<double> postWalletEntry(
    String groupId,
    String walletId, {
    required String direction, // 'DR' | 'CR'
    required double amount,
    required String source,
    String? note,
    String? refTransactionId,
    String? byName,
    String? byPhone,
    void Function(Transaction tx)? alsoWrite,
  }) {
    final signed = direction == 'CR' ? -amount.abs() : amount.abs();
    return _postWallet(
      groupId,
      walletId,
      computeSigned: (_) => signed,
      source: source,
      note: note,
      refTransactionId: refTransactionId,
      byName: byName,
      byPhone: byPhone,
      alsoWrite: alsoWrite,
    );
  }

  /// Backwards-compatible signed delta (used by expense/reversal flows). A
  /// negative delta credits the wallet, a positive delta debits it.
  ///
  /// [alsoWrite] lets a caller fold ANOTHER write (e.g. the TransactionModel
  /// document this ledger entry belongs to) into the SAME Firestore
  /// transaction as the balance update and ledger entry — either everything
  /// commits together or nothing does. Without this, a transaction document
  /// and its wallet effect are two independent network calls that can
  /// partially fail, leaving one collection without the other (exactly the
  /// bug behind old workers' wallet entries with no transaction record).
  Future<double> applyWalletDelta(
    String groupId,
    String walletId,
    double delta, {
    String source = 'adjustment',
    String? note,
    String? refTransactionId,
    String? byName,
    String? byPhone,
    void Function(Transaction tx)? alsoWrite,
  }) {
    if (walletId.trim().isEmpty) return Future.value(0);
    return _postWallet(
      groupId,
      walletId,
      computeSigned: (_) => delta,
      source: source,
      note: note,
      refTransactionId: refTransactionId,
      byName: byName,
      byPhone: byPhone,
      alsoWrite: alsoWrite,
    );
  }

  /// Core ledger transaction: lazily creates an opening entry for legacy
  /// wallets, appends the new entry with its accumulated balance, and updates
  /// the parent wallet — all atomically. [alsoWrite] runs inside the same
  /// Firestore transaction, so a caller can pair another document write with
  /// this wallet effect and get true all-or-nothing atomicity across both.
  Future<double> _postWallet(
    String groupId,
    String walletId, {
    required double Function(double current) computeSigned,
    required String source,
    String? note,
    String? refTransactionId,
    String? byName,
    String? byPhone,
    void Function(Transaction tx)? alsoWrite,
  }) async {
    final walletRef = _wallets(groupId).doc(walletId);
    final entriesRef = walletRef.collection('entries');
    return _fs.runTransaction<double>((tx) async {
      final snap = await tx.get(walletRef);
      if (!snap.exists) {
        alsoWrite?.call(tx);
        return 0; // wallet gone (e.g. archived) → no-op on the wallet side
      }
      final data = snap.data() ?? <String, dynamic>{};
      final current = (data['balance'] as num?)?.toDouble() ?? 0;
      final ledgerStarted = data['ledgerStarted'] == true;
      final createdAt =
          (data['createdAt'] as String?) ?? DateTime.now().toIso8601String();
      final signed = computeSigned(current);
      if (signed == 0) {
        alsoWrite?.call(tx);
        return current;
      }

      final nowIso = DateTime.now().toIso8601String();

      // Legacy wallets created before the ledger existed: anchor their current
      // balance with an opening entry so the running balance reconciles.
      if (!ledgerStarted && current != 0) {
        final openRef = entriesRef.doc();
        tx.set(openRef, {
          'id': openRef.id,
          'walletId': walletId,
          'direction': current >= 0 ? 'DR' : 'CR',
          'amount': current.abs(),
          'balanceAfter': current,
          'at': createdAt,
          'source': 'opening',
          'note': 'رصيد افتتاحي',
          'byName': data['updatedByName'],
          'byPhone': data['updatedByPhone'],
        });
      }

      final running = current + signed;
      final entryRef = entriesRef.doc();
      tx.set(entryRef, {
        'id': entryRef.id,
        'walletId': walletId,
        'direction': signed >= 0 ? 'DR' : 'CR',
        'amount': signed.abs(),
        'balanceAfter': running,
        'at': nowIso,
        'source': source,
        'note': note,
        'refTransactionId': refTransactionId,
        'byName': byName,
        'byPhone': byPhone,
      });

      tx.set(walletRef, {
        'balance': running,
        'updatedAt': nowIso,
        'updatedByName': byName,
        'updatedByPhone': byPhone,
        'ledgerStarted': true,
      }, SetOptions(merge: true));

      alsoWrite?.call(tx);
      return running;
    });
  }

  /// The wallet's ledger, oldest entry first.
  Future<List<WalletEntryModel>> getWalletEntriesSync(
      String groupId, String walletId) async {
    final q = await _walletEntries(groupId, walletId).get();
    final list = q.docs
        .map((d) => WalletEntryModel.fromMap({...d.data(), 'id': d.id}))
        .toList();
    list.sort((a, b) => a.at.compareTo(b.at));
    return list;
  }

  // ─── Expense Categories + Budgets ───
  // Categories are fully dynamic: seeded once per family (see
  // ensureCategoriesSeeded) from CategorySeeds, then admin-editable from
  // there — replacing the old hardcoded AppConstants/AIService tables.
  Future<List<CategoryModel>> getCategoriesSync(String groupId,
      {bool includeHidden = false}) async {
    final q = await _categories(groupId).orderBy('createdAt').get();
    return q.docs
        .map((d) => CategoryModel.fromMap({...d.data(), 'id': d.id}))
        .where((c) => includeHidden || !c.hidden)
        .toList();
  }

  /// Back-compat: expense category display names only, as a flat list.
  Future<List<String>> getExpenseCategoriesSync(String groupId) async {
    final categories = await getCategoriesSync(groupId);
    final bq = await _budgets(groupId).get();
    final budgetNames = bq.docs
        .map((d) => (d.data()['category'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toList();
    final result = <String>[];
    final seen = <String>{};
    for (final name in [
      ...categories.where((c) => !c.isIncome).map((c) => c.name),
      ...budgetNames,
    ]) {
      final key = _categoryKey(name);
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      result.add(name);
    }
    return result;
  }

  /// Writes the 19 built-in expense + 5 income categories as real documents,
  /// once per family. No-op if the family already has ANY category doc (a
  /// brand-new family is seeded at creation; an existing family is seeded the
  /// next time it loads — see BudgetProvider._ensureProvisioned). This never
  /// touches transactions/budgets — it only populates the category catalog.
  Future<void> ensureCategoriesSeeded(String groupId) async {
    final existing = await _categories(groupId).limit(1).get();
    if (existing.docs.isNotEmpty) return;
    final batch = _fs.batch();
    for (final c in [
      ...CategorySeeds.builtInExpenseCategories,
      ...CategorySeeds.builtInIncomeCategories,
    ]) {
      batch.set(_categories(groupId).doc(c.id), c.toMap());
    }
    await batch.commit();
  }

  Future<void> addExpenseCategory(
    String groupId,
    String category, {
    double? limit,
    List<String>? keywords,
    String? icon,
    bool isIncome = false,
  }) async {
    final clean = category.trim();
    if (clean.isEmpty) return;
    await _ensureCategoryStored(groupId, clean,
        keywords: keywords, icon: icon, isIncome: isIncome);
    if (limit != null && limit >= 0) {
      await setBudget(groupId, clean, limit);
    }
  }

  Future<void> removeExpenseCategory(String groupId, String category) async {
    final clean = category.trim();
    if (clean.isEmpty) return;
    final ref = await _findCategoryRefByName(groupId, clean) ??
        _categories(groupId).doc(_docSafeId(clean));
    await ref.set({
      'name': clean,
      'hidden': true,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
    await _budgets(groupId).doc(_docSafeId(clean)).delete();
  }

  Future<void> updateCategoryIcon(
      String groupId, String categoryId, String icon) async {
    await _categories(groupId).doc(categoryId).set({
      'icon': icon,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  Future<void> updateCategoryKeywords(
      String groupId, String categoryId, List<String> keywords) async {
    await _categories(groupId).doc(categoryId).set({
      'keywords': keywords,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  Future<List<BudgetModel>> getBudgetsSync(String groupId) async {
    final q = await _budgets(groupId).get();
    final txns = await getTransactionsSync(groupId);
    final existing = q.docs.map((d) => BudgetModel.fromMap(d.data())).toList();
    existing.sort((a, b) => a.category.compareTo(b.category));
    return existing
        .map((b) => b.copyWith(
              spent: _spentForCategory(txns, b.category, period: b.period),
            ))
        .toList();
  }

  Future<void> setBudget(
    String groupId,
    String category,
    double limit, {
    String period = 'monthly',
  }) async {
    final clean = category.trim();
    if (clean.isEmpty) return;
    await _ensureCategoryStored(groupId, clean);
    final txns = await getTransactionsSync(groupId);
    final normalizedPeriod = _normalizeBudgetPeriod(period);
    final spent = _spentForCategory(txns, clean, period: normalizedPeriod);
    await _budgets(groupId).doc(_docSafeId(clean)).set({
      'category': clean,
      'limit': limit,
      'spent': spent,
      'period': normalizedPeriod,
      'periodKey': _periodKey(normalizedPeriod),
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  /// Finds an existing category doc by its display NAME (works for both
  /// legacy name-keyed docs and new uuid-keyed ones) — categories have no
  /// other identity to search by until the caller already has an id.
  Future<DocumentReference<Map<String, dynamic>>?> _findCategoryRefByName(
      String groupId, String name) async {
    final key = _categoryKey(name);
    if (key.isEmpty) return null;
    final q = await _categories(groupId).get();
    for (final d in q.docs) {
      final docName = (d.data()['name'] ?? d.id).toString();
      if (_categoryKey(docName) == key) return d.reference;
    }
    return null;
  }

  Future<void> _ensureCategoryStored(
    String groupId,
    String category, {
    List<String>? keywords,
    String? icon,
    bool isIncome = false,
  }) async {
    final clean = category.trim();
    if (clean.isEmpty) return;
    final existingRef = await _findCategoryRefByName(groupId, clean);
    if (existingRef != null) {
      await existingRef.set({
        'name': clean,
        'hidden': false,
        if (keywords != null) 'keywords': keywords,
        if (icon != null) 'icon': icon,
        'updatedAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));
      return;
    }
    final id = _uuid.v4();
    await _categories(groupId).doc(id).set({
      'id': id,
      'name': clean,
      'icon': icon ?? '📌',
      'keywords': keywords ?? <String>[],
      'isIncome': isIncome,
      'hidden': false,
      'isBuiltIn': false,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  // ─── Offline learning: keyword → category, taught by user corrections ───

  /// Returns a map of normalized-keyword-key → category.
  Future<Map<String, String>> getLearnedKeywordsSync(String groupId) async {
    final q = await _learnedKeywords(groupId).get();
    final map = <String, String>{};
    for (final d in q.docs) {
      final data = d.data();
      final kw = (data['keyword'] ?? '').toString();
      final cat = (data['category'] ?? '').toString();
      final key = CategoryUtils.key(kw);
      if (key.isNotEmpty && cat.isNotEmpty) map[key] = cat;
    }
    return map;
  }

  /// Learned word→category entries WITH their doc id, for the admin review
  /// screen (so wrong ones can be deleted).
  Future<List<Map<String, String>>> getLearnedKeywordEntries(
      String groupId) async {
    final q = await _learnedKeywords(groupId).get();
    final list = <Map<String, String>>[];
    for (final d in q.docs) {
      final data = d.data();
      final kw = (data['keyword'] ?? '').toString();
      final cat = (data['category'] ?? '').toString();
      if (kw.isEmpty || cat.isEmpty) continue;
      list.add({'id': d.id, 'keyword': kw, 'category': cat});
    }
    list.sort((a, b) => a['keyword']!.compareTo(b['keyword']!));
    return list;
  }

  Future<void> deleteLearnedKeyword(String groupId, String id) async {
    await _learnedKeywords(groupId).doc(id).delete();
  }

  Future<void> addLearnedKeyword(
      String groupId, String keyword, String category) async {
    final kw = keyword.trim();
    final cat = category.trim();
    if (kw.isEmpty || cat.isEmpty) return;
    final id = _docSafeId(kw);
    if (id.isEmpty) return;
    await _learnedKeywords(groupId).doc(id).set({
      'keyword': kw,
      'category': cat,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  /// Corrects an expense's category everywhere (transaction + chat message) and
  /// teaches the parser the distinctive words from the original text.
  Future<void> recategorizeExpense(
      String groupId, String transactionId, String category) async {
    final txnRef = _transactions(groupId).doc(transactionId);
    final txnDoc = await txnRef.get();
    if (!txnDoc.exists) return;
    final txnData = txnDoc.data()!;
    final txnNote = (txnData['note'] ?? '').toString();
    final amount = (txnData['amount'] as num?)?.toDouble() ?? 0;
    final isExpense = txnData['isExpense'] != false;
    final description =
        buildExpenseDescription(rawText: txnNote, categoryName: category);
    await txnRef.set({
      'category': category,
      'description': description,
    }, SetOptions(merge: true));

    final q = await _messages(groupId)
        .where('transactionId', isEqualTo: transactionId)
        .limit(1)
        .get();
    if (q.docs.isNotEmpty) {
      await q.docs.first.reference.update({
        'category': category,
        'content': buildExpenseBubbleContent(
            isExpense: isExpense, amount: amount, rawText: txnNote),
      });
    }

    // Teach: map the meaningful words of the original text to this category.
    for (final token in CategoryUtils.meaningfulTokens(txnNote)) {
      if (token.length >= 3) await addLearnedKeyword(groupId, token, category);
    }
    await recalculateBudgetsForCurrentMonth(groupId);
  }

  // ─── Family Notifications ───
  Future<List<FamilyNotificationModel>> getNotificationsSync(
      String groupId) async {
    final q = await _notifications(groupId)
        .orderBy('timestamp', descending: true)
        .limit(100)
        .get();
    return q.docs
        .map((d) => FamilyNotificationModel.fromMap(d.data()))
        .toList();
  }

  Stream<List<FamilyNotificationModel>> watchNotifications(String groupId) {
    return _notifications(groupId)
        .orderBy('timestamp', descending: true)
        .limit(100)
        .snapshots()
        .map((q) => q.docs
            .map((d) => FamilyNotificationModel.fromMap(d.data()))
            .toList());
  }

  Future<void> addFamilyNotification(FamilyNotificationModel item) async {
    await _notifications(item.groupId).doc(item.id).set(item.toMap());
  }

  /// Shared "notify everyone affected by a money event" helper — dedupes what
  /// every fund/withdraw/transfer/delete call site used to hand-build inline.
  Future<void> notifyMultiple(
    String groupId, {
    required String title,
    required String body,
    required String actorId,
    required String actorName,
    required List<String> targetUserIds,
  }) =>
      addFamilyNotification(FamilyNotificationModel(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        groupId: groupId,
        title: title,
        body: body,
        actorId: actorId,
        actorName: actorName,
        timestamp: DateTime.now(),
        targetUserIds: targetUserIds,
      ));

  Future<void> markNotificationsRead(String groupId, String userId) async {
    final q = await _notifications(groupId).limit(100).get();
    final batch = _fs.batch();
    for (final doc in q.docs) {
      batch.set(
          doc.reference,
          {
            'readBy': FieldValue.arrayUnion([userId]),
          },
          SetOptions(merge: true));
    }
    await batch.commit();
  }

  Future<void> clearNotifications(String groupId) async {
    await _deleteQuerySnapshot(await _notifications(groupId).limit(500).get());
  }

  // ─── Admin factory reset ───
  /// Hard-reset every money account in the family back to zero while KEEPING
  /// the people (members + teams) and the structure (wallets, categories,
  /// budget limits). It:
  ///   • deletes all transactions (expenses/income),
  ///   • empties every wallet's ledger and sets its balance to 0 (the wallet
  ///     doc itself stays, so each member keeps their wallet),
  ///   • zeroes every budget's `spent` (limits are kept) and every member's
  ///     `currentSpending`,
  ///   • clears the chat feed and notifications (they are full of now-orphaned
  ///     money/expense entries).
  /// Members, teams, wallets, categories and budget limits are preserved.
  /// This is irreversible — callers must confirm with the admin first.
  Future<void> factoryResetFamily(String groupId) async {
    final nowIso = DateTime.now().toIso8601String();

    // 1) All transactions.
    await _wipeCollection(_transactions(groupId));

    // 2) Every wallet: empty its ledger, zero its balance, keep the wallet.
    final walletsSnap = await _wallets(groupId).get();
    for (final w in walletsSnap.docs) {
      await _wipeCollection(_walletEntries(groupId, w.id));
      await w.reference.set({
        'balance': 0,
        'ledgerStarted': false,
        'updatedAt': nowIso,
      }, SetOptions(merge: true));
    }

    // 3) Zero budgets' spent (keep limits) and members' currentSpending.
    final budgetsSnap = await _budgets(groupId).get();
    if (budgetsSnap.docs.isNotEmpty) {
      final batch = _fs.batch();
      for (final b in budgetsSnap.docs) {
        batch.set(b.reference, {'spent': 0, 'updatedAt': nowIso},
            SetOptions(merge: true));
      }
      await batch.commit();
    }
    final membersSnap = await _members(groupId).get();
    if (membersSnap.docs.isNotEmpty) {
      final batch = _fs.batch();
      for (final m in membersSnap.docs) {
        batch.set(m.reference, {'currentSpending': 0}, SetOptions(merge: true));
      }
      await batch.commit();
    }

    // 4) Clear the chat feed + notifications (now-orphaned money entries).
    await _wipeCollection(_messages(groupId));
    await _wipeCollection(_notifications(groupId));
  }

  /// Page through [query]'s results in batches of 400 and merge-apply
  /// [buildUpdate]'s returned fields to each doc, committing per page,
  /// looping until a page returns fewer than 400 docs. Mirrors
  /// _wipeCollection's pagination shape but updates instead of deletes.
  /// Naturally idempotent for "where field == oldValue"-style queries: once a
  /// doc is updated it no longer matches, so a re-run only touches whatever
  /// is still unmigrated.
  Future<void> _updateCollectionWhere(
    Query<Map<String, dynamic>> query,
    Map<String, dynamic> Function(Map<String, dynamic> data) buildUpdate,
  ) async {
    while (true) {
      final snap = await query.limit(400).get();
      if (snap.docs.isEmpty) break;
      final batch = _fs.batch();
      for (final doc in snap.docs) {
        batch.set(doc.reference, buildUpdate(doc.data()), SetOptions(merge: true));
      }
      await batch.commit();
      if (snap.docs.length < 400) break;
    }
  }

  /// Delete every document in a (sub)collection in batches — Firestore caps a
  /// single batch at 500 writes, so we page until the collection is empty.
  Future<void> _wipeCollection(
      CollectionReference<Map<String, dynamic>> ref) async {
    while (true) {
      final snap = await ref.limit(400).get();
      if (snap.docs.isEmpty) break;
      final batch = _fs.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
      if (snap.docs.length < 400) break;
    }
  }

  // ─── Accounting Engine ───
  String _normalizeBudgetPeriod(String period) {
    if (period == 'daily' || period == 'weekly' || period == 'monthly') {
      return period;
    }
    return 'monthly';
  }

  DateTime _periodStart(String period, [DateTime? now]) {
    final d = now ?? DateTime.now();
    final today = DateTime(d.year, d.month, d.day);
    switch (_normalizeBudgetPeriod(period)) {
      case 'daily':
        return today;
      case 'weekly':
        return today.subtract(Duration(days: today.weekday - 1));
      default:
        return DateTime(d.year, d.month);
    }
  }

  String _periodKey(String period, [DateTime? now]) {
    final start = _periodStart(period, now);
    return '${_normalizeBudgetPeriod(period)}-${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
  }

  bool _transactionMatchesBudget(
    TransactionModel t,
    String category, {
    String period = 'monthly',
  }) {
    if (!t.isExpense) return false;
    final txDay = DateTime(t.date.year, t.date.month, t.date.day);
    if (txDay.isBefore(_periodStart(period))) return false;
    final budgetKey = _categoryKey(category);
    if (budgetKey.isEmpty || budgetKey == _categoryKey('أخرى')) return false;

    // Direct saved category match.
    if (_categoryKey(t.category) == budgetKey) return true;

    final note = t.note ?? '';
    final combined = '${t.category} $note';

    // Match custom budgets from the original text even if the transaction was saved as "أخرى".
    // Examples: "دفعت 100 لمحمد من مصروفه" -> category "مصروف محمد" or "محمد".
    if (note.isNotEmpty && CategoryUtils.textMatchesCategory(note, category))
      return true;
    if (CategoryUtils.textMatchesCategory(combined, category)) return true;

    final budgetTokens = CategoryUtils.meaningfulTokens(category);
    final textKey = CategoryUtils.key(combined);
    if (budgetTokens.isNotEmpty &&
        budgetTokens.every((t) => textKey.contains(CategoryUtils.key(t)))) {
      return true;
    }

    return false;
  }

  String _resolvedDisplayCategory(TransactionModel t, List<String> categories) {
    final directKey = _categoryKey(t.category);
    for (final cat in categories) {
      if (_categoryKey(cat) == directKey) return cat;
    }

    // Prefer custom/narrow categories if the original text contains them.
    final sorted = categories
        .where((c) =>
            c.trim().isNotEmpty && _categoryKey(c) != _categoryKey('أخرى'))
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final combined = '${t.category} ${t.note ?? ''}';
    for (final cat in sorted) {
      if (CategoryUtils.textMatchesCategory(combined, cat)) return cat;
    }
    return t.category.isEmpty ? 'أخرى' : t.category;
  }

  double _spentForCategory(
    List<TransactionModel> txns,
    String category, {
    String period = 'monthly',
  }) {
    return txns
        .where((t) => _transactionMatchesBudget(t, category, period: period))
        .fold<double>(0.0, (sum, t) => sum + t.amount);
  }

  Future<void> recalculateBudgetsForCurrentMonth(String groupId) async {
    final q = await _budgets(groupId).get();
    if (q.docs.isEmpty) return;
    final txns = await getTransactionsSync(groupId);
    final batch = _fs.batch();
    for (final doc in q.docs) {
      final data = doc.data();
      final category = (data['category'] ?? '').toString();
      final period =
          _normalizeBudgetPeriod((data['period'] ?? 'monthly').toString());
      final spent = _spentForCategory(txns, category, period: period);
      batch.set(
          doc.reference,
          {
            ...data,
            'spent': spent,
            'period': period,
            'periodKey': _periodKey(period),
            'updatedAt': DateTime.now().toIso8601String(),
          },
          SetOptions(merge: true));
    }
    await batch.commit();
  }

  // ─── Reports ───
  Future<List<String>> buildReportLines(
    String groupId, {
    String? memberName,
    int days = 30,
    bool includeBudgets = false,
  }) async {
    final txns = await getTransactionsSync(groupId);
    final categories = await getExpenseCategoriesSync(groupId);
    final displayByKey = <String, String>{};
    for (final cat in categories) {
      displayByKey[_categoryKey(cat)] = cat;
    }

    final now = DateTime.now();
    final since = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: days <= 1 ? 0 : days - 1));
    final normalizedMember =
        memberName == null ? null : CategoryUtils.normalize(memberName.trim());

    final filtered = txns.where((t) {
      final txDay = DateTime(t.date.year, t.date.month, t.date.day);
      final inPeriod = !txDay.isBefore(since);
      final matchesMember = normalizedMember == null ||
          normalizedMember.isEmpty ||
          CategoryUtils.normalize(t.userName).contains(normalizedMember) ||
          normalizedMember.contains(CategoryUtils.normalize(t.userName));
      return inPeriod && matchesMember;
    }).toList();

    final expenses = filtered
        .where((t) => t.isExpense)
        .fold<double>(0.0, (sum, t) => sum + t.amount);
    final byCategory = <String, double>{};
    for (final t in filtered.where((t) => t.isExpense)) {
      final display = _resolvedDisplayCategory(t, categories);
      byCategory[display] = (byCategory[display] ?? 0) + t.amount;
    }
    final top = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Funding (money in) + current balance from the wallet ledger — consistent
    // with the Reports screen (funding is a ledger record, not a transaction).
    final wallets = await getWalletsSync(groupId);
    final memberScope =
        normalizedMember != null && normalizedMember.isNotEmpty;
    List<WalletModel> relevant;
    if (memberScope) {
      final members = await getMembersSync(groupId);
      String? memberId;
      for (final m in members) {
        final mn = CategoryUtils.normalize(m.name);
        if (mn.isNotEmpty &&
            (mn.contains(normalizedMember) || normalizedMember.contains(mn))) {
          memberId = m.id;
          break;
        }
      }
      relevant = memberId == null
          ? <WalletModel>[]
          : wallets
              .where((w) => w.isMemberWallet && w.ownerId == memberId)
              .toList();
    } else {
      // Whole-family balance = the admin's own cash sources only, matching
      // BudgetProvider.adminWalletBalance and WalletsOverviewScreen — a
      // member's or worker's own wallet is their asset, not the family's.
      relevant = wallets.where((w) => w.isAdminWallet).toList();
    }
    final balance = relevant.fold<double>(0.0, (s, w) => s + w.balance);
    var funded = 0.0;
    for (final w in relevant) {
      final entries = await getWalletEntriesSync(groupId, w.id);
      for (final e in entries) {
        if (!e.isDebit || e.at.isBefore(since)) continue;
        if (memberScope || e.source == 'opening' || e.source == 'injection') {
          funded += e.amount;
        }
      }
    }

    final title = memberName == null || memberName.trim().isEmpty
        ? 'تقرير العائلة'
        : 'تقرير ${memberName.trim()}';
    final period = days <= 1
        ? 'اليوم'
        : days <= 7
            ? 'آخر أسبوع'
            : days <= 30
                ? 'آخر شهر'
                : 'آخر $days يوم';
    final lines = <String>[
      '📊 $title — $period',
      'إجمالي التمويل: ${formatMoney(funded)} ج',
      'إجمالي المصروفات: ${formatMoney(expenses)} ج',
      'الرصيد الحالي: ${formatMoney(balance)} ج',
    ];

    if (top.isNotEmpty) {
      lines.add('أكبر بنود الصرف:');
      for (final e in top.take(8)) {
        lines.add('• ${e.key}: ${formatMoney(e.value)} ج');
      }
    } else {
      lines.add('لا توجد مصروفات مسجلة في هذه الفترة.');
    }

    final budgets = await getBudgetsSync(groupId);
    if (includeBudgets || budgets.isNotEmpty) {
      lines.add('—');
      lines.add('حدود الميزانية لهذا الشهر:');
      if (budgets.isEmpty) {
        lines.add('لا توجد حدود ميزانية محددة بعد.');
      } else {
        for (final b in budgets) {
          final remaining = b.limit - b.spent;
          final status = remaining >= 0
              ? 'متبقي ${formatMoney(remaining)} ج'
              : 'تجاوز ${formatMoney(-remaining)} ج';
          lines.add(
              '• ${b.category}: حد ${b.periodLabel} ${formatMoney(b.limit)} ج — صرف ${formatMoney(b.spent)} ج — $status');
        }
      }
    }
    return lines;
  }

  Future<String> buildTextReport(
    String groupId, {
    String? memberName,
    int days = 30,
    bool includeBudgets = false,
  }) async {
    final lines = await buildReportLines(
      groupId,
      memberName: memberName,
      days: days,
      includeBudgets: includeBudgets,
    );
    return lines.join('\n');
  }

  String _categoryKey(String value) => CategoryUtils.key(value);

  Future<void> _deleteQuerySnapshot(
      QuerySnapshot<Map<String, dynamic>> snapshot) async {
    if (snapshot.docs.isEmpty) return;
    final batch = _fs.batch();
    for (final doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }

  String _encode(Map<String, dynamic> map) => map.entries
      .map((e) =>
          '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent('${e.value ?? ''}')}')
      .join('&');

  Map<String, dynamic> _decode(String data) {
    final result = <String, dynamic>{};
    for (final part in data.split('&')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      result[Uri.decodeComponent(part.substring(0, idx))] =
          Uri.decodeComponent(part.substring(idx + 1));
    }
    // Restore primitive types that were stringified for the local session.
    for (final key in [
      'isAdmin',
      'canAddExpenses',
      'canManageMembers',
      'canManageBudgets',
      'phoneVerified'
    ]) {
      if (result[key] == 'true') result[key] = true;
      if (result[key] == 'false') result[key] = false;
    }
    for (final key in ['monthlyLimit', 'currentSpending']) {
      if (result[key] != null)
        result[key] = double.tryParse(result[key].toString()) ?? 0.0;
    }
    return result;
  }
}

/// Thrown by [DatabaseService.createFamily] when the family name is taken.
class FamilyNameTakenException implements Exception {
  final String name;
  FamilyNameTakenException(this.name);
  @override
  String toString() => 'اسم العائلة "$name" مستخدم بالفعل. اختر اسمًا مختلفًا.';
}

/// Thrown by [DatabaseService.joinFamily] when the family can't be joined.
class JoinFamilyException implements Exception {
  final String message;
  JoinFamilyException(this.message);
  @override
  String toString() => message;
}
