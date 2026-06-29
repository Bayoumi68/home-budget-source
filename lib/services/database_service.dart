import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';
import '../models/chat_message_model.dart';
import '../models/transaction_model.dart';
import '../models/budget_model.dart';
import '../models/group_model.dart';
import '../models/family_notification_model.dart';
import '../models/wallet_model.dart';
import '../models/wallet_entry_model.dart';
import '../models/team_model.dart';
import '../config/constants.dart';
import '../services/auth_service.dart';
import '../utils/category_utils.dart';

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
  CollectionReference<Map<String, dynamic>> _learnedKeywords(String groupId) =>
      _families.doc(groupId).collection('learnedKeywords');

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
      canViewReports: true,
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
        canViewReports: true,
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

  /// All family memberships bound to a login [authUid] (for session restore).
  Future<List<FamilyMembership>> getMembershipsByAuthUid(String authUid) async {
    if (authUid.trim().isEmpty) return const [];
    final q = await _fs
        .collectionGroup('members')
        .where('authUid', isEqualTo: authUid)
        .limit(20)
        .get();
    final byGroup = <String, FamilyMembership>{};
    for (final doc in q.docs) {
      final groupRef = doc.reference.parent.parent;
      if (groupRef == null || byGroup.containsKey(groupRef.id)) continue;
      final group = await getGroupById(groupRef.id);
      if (group == null) continue;
      byGroup[group.id] =
          FamilyMembership(group: group, member: UserModel.fromMap(doc.data()));
    }
    final items = byGroup.values.toList()
      ..sort((a, b) => a.group.name.compareTo(b.group.name));
    return items;
  }

  /// Admin pre-registers a member slot (pending until they join with their own
  /// credentials). The assigned [phone] is what goes into their invite link.
  Future<UserModel> addPendingMember(
    String groupId, {
    required String name,
    required String phone,
    bool canAddExpenses = true,
    bool canViewReports = true,
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
      canViewReports: canViewReports,
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

    // Reuse an existing slot if this login or phone already maps to a member.
    UserModel? existing;
    try {
      final q = await _members(groupId)
          .where('authUid', isEqualTo: authUid)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty) existing = UserModel.fromMap(q.docs.first.data());
    } catch (_) {}
    if (existing == null && normalizedPhone.isNotEmpty) {
      existing = await getMemberByPhone(groupId, normalizedPhone);
    }

    final memberId = existing?.id ??
        (normalizedPhone.isEmpty
            ? 'u_${_docSafeId(authUid)}'
            : _authService.memberIdForPhone(normalizedPhone));

    // A team code makes the joiner a WORKER of that team (not a family member).
    final isWorker = teamId.isNotEmpty;
    final base = existing ??
        UserModel(
          id: memberId,
          name: name,
          phone: normalizedPhone.isEmpty ? null : normalizedPhone,
          teamId: isWorker ? teamId : null,
          canAddExpenses: true,
          canViewReports: !isWorker,
          canManageMembers: false,
          canManageBudgets: false,
        );
    final toSave = base.copyWith(
      id: memberId,
      name: base.name.trim().isEmpty ? name : base.name,
      phone: normalizedPhone.isEmpty ? base.phone : normalizedPhone,
      teamId: isWorker ? teamId : base.teamId,
      authUid: authUid,
      email: email,
      phoneVerified: true,
    );
    await _members(groupId)
        .doc(toSave.id)
        .set(toSave.toMap(), SetOptions(merge: true));

    try {
      await provisionMemberWallets(groupId);
    } catch (_) {}
    if (teamId.isNotEmpty) {
      try {
        await addTeamMember(groupId, teamId, toSave);
      } catch (_) {}
    }

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
          canViewReports: false,
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

  Future<void> updateMemberPermissions(
    String groupId,
    String userId, {
    bool? canAddExpenses,
    bool? canViewReports,
    bool? canManageMembers,
    bool? canManageBudgets,
  }) async {
    await updateMember(
      groupId,
      userId,
      (member) => member.copyWith(
        canAddExpenses: canAddExpenses,
        canViewReports: canViewReports,
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

  Future<void> removeMember(String groupId, String userId) async {
    await _members(groupId).doc(userId).delete();
  }

  Future<double> getMemberMonthlySpending(String groupId, String userId) async {
    final now = DateTime.now();
    final txns = await getTransactionsSync(groupId);
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

  /// Remove a worker from a team and delete their worker record + archive their
  /// wallet (workers belong to the team, not the family).
  Future<void> removeWorker(
      String groupId, TeamModel team, String workerId) async {
    await removeTeamMember(groupId, team, workerId);
    await _members(groupId).doc(workerId).delete();
    final wid = 'mem_${_docSafeId(workerId)}';
    await _wallets(groupId).doc(wid).set({
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

  Future<void> deleteTeam(String groupId, String teamId) async {
    final txns = await getTeamTransactions(groupId, teamId);
    final batch = _fs.batch();
    for (final txn in txns) {
      batch.delete(_transactions(groupId).doc(txn.id));
    }
    batch.delete(_teams(groupId).doc(teamId));
    await batch.commit();
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
          'تم حذف هذا الإدخال وإرجاع ${amount.toStringAsFixed(0)} ج من $category إلى الميزانية',
    });
  }

  Future<void> clearMessages(String groupId) async {
    await _deleteQuerySnapshot(await _messages(groupId).limit(500).get());
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

  Future<TransactionModel?> deleteTransaction(
      String groupId, String transactionId) async {
    final doc = await _transactions(groupId).doc(transactionId).get();
    if (!doc.exists || doc.data() == null) return null;
    final deleted = TransactionModel.fromMap(doc.data()!);
    await doc.reference.delete();
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
    String? phone,
  }) async {
    final normalizedPhone = (phone ?? '').trim().isEmpty
        ? ''
        : _authService.normalizePhone(phone!.trim());
    final id = normalizedPhone.isEmpty
        ? 'wrk_${_docSafeId('${teamId}_${DateTime.now().millisecondsSinceEpoch}')}'
        : _authService.memberIdForPhone(normalizedPhone);
    final worker = UserModel(
      id: id,
      name: name.trim().isEmpty ? 'عامل' : name.trim(),
      phone: normalizedPhone.isEmpty ? null : normalizedPhone,
      teamId: teamId,
      canAddExpenses: true,
      canViewReports: false,
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
  /// source, DR the destination. Returns an Arabic error, or null on success.
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
    final fromSnap = await _wallets(groupId).doc(fromWalletId).get();
    final toSnap = await _wallets(groupId).doc(toWalletId).get();
    if (!fromSnap.exists || !toSnap.exists) return 'المحفظة غير موجودة.';
    final fromBal = (fromSnap.data()?['balance'] as num?)?.toDouble() ?? 0;
    final fromName = (fromSnap.data()?['name'] ?? 'المحفظة').toString();
    final toName = (toSnap.data()?['name'] ?? 'المحفظة').toString();
    if (amount > fromBal + 0.005) {
      return 'الرصيد غير كافٍ في $fromName.';
    }
    await postWalletEntry(groupId, fromWalletId,
        direction: 'CR',
        amount: amount,
        source: 'transfer',
        note: 'تحويل إلى $toName',
        byName: byName,
        byPhone: byPhone);
    await postWalletEntry(groupId, toWalletId,
        direction: 'DR',
        amount: amount,
        source: 'transfer',
        note: 'تحويل من $fromName',
        byName: byName,
        byPhone: byPhone);
    return null;
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
    );
  }

  /// Backwards-compatible signed delta (used by expense/reversal flows). A
  /// negative delta credits the wallet, a positive delta debits it.
  Future<double> applyWalletDelta(
    String groupId,
    String walletId,
    double delta, {
    String source = 'adjustment',
    String? note,
    String? refTransactionId,
    String? byName,
    String? byPhone,
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
    );
  }

  /// Core ledger transaction: lazily creates an opening entry for legacy
  /// wallets, appends the new entry with its accumulated balance, and updates
  /// the parent wallet — all atomically.
  Future<double> _postWallet(
    String groupId,
    String walletId, {
    required double Function(double current) computeSigned,
    required String source,
    String? note,
    String? refTransactionId,
    String? byName,
    String? byPhone,
  }) async {
    final walletRef = _wallets(groupId).doc(walletId);
    final entriesRef = walletRef.collection('entries');
    return _fs.runTransaction<double>((tx) async {
      final snap = await tx.get(walletRef);
      if (!snap.exists) return 0; // wallet gone (e.g. archived) → no-op
      final data = snap.data() ?? <String, dynamic>{};
      final current = (data['balance'] as num?)?.toDouble() ?? 0;
      final ledgerStarted = data['ledgerStarted'] == true;
      final createdAt =
          (data['createdAt'] as String?) ?? DateTime.now().toIso8601String();
      final signed = computeSigned(current);
      if (signed == 0) return current;

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
  Future<List<String>> getExpenseCategoriesSync(String groupId) async {
    final q = await _categories(groupId).orderBy('createdAt').get();
    final bq = await _budgets(groupId).get();
    final hiddenKeys = q.docs
        .where((d) => d.data()['hidden'] == true)
        .map((d) => _categoryKey((d.data()['name'] ?? d.id).toString()))
        .where((key) => key.isNotEmpty)
        .toSet();
    final saved = q.docs
        .where((d) => d.data()['hidden'] != true)
        .map((d) => (d.data()['name'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toList();
    final budgetNames = bq.docs
        .map((d) => (d.data()['category'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toList();
    final result = <String>[];
    final seen = <String>{};
    for (final name in [
      ...AppConstants.expenseCategories,
      ...saved,
      ...budgetNames
    ]) {
      final key = _categoryKey(name);
      if (key.isEmpty || seen.contains(key) || hiddenKeys.contains(key)) {
        continue;
      }
      seen.add(key);
      result.add(name);
    }
    return result;
  }

  Future<void> addExpenseCategory(
    String groupId,
    String category, {
    double? limit,
  }) async {
    final clean = category.trim();
    if (clean.isEmpty) return;
    await _ensureCategoryStored(groupId, clean);
    if (limit != null && limit >= 0) {
      await setBudget(groupId, clean, limit);
    }
  }

  Future<void> removeExpenseCategory(String groupId, String category) async {
    final clean = category.trim();
    if (clean.isEmpty) return;
    final id = _docSafeId(clean);
    await _categories(groupId).doc(id).set({
      'name': clean,
      'hidden': true,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
    await _budgets(groupId).doc(id).delete();
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

  Future<void> _ensureCategoryStored(String groupId, String category) async {
    final clean = category.trim();
    if (clean.isEmpty) return;
    await _categories(groupId).doc(_docSafeId(clean)).set({
      'name': clean,
      'hidden': false,
      'createdAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
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
    final txnNote = (txnDoc.data()?['note'] ?? '').toString();
    await txnRef.set({'category': category}, SetOptions(merge: true));

    final q = await _messages(groupId)
        .where('transactionId', isEqualTo: transactionId)
        .limit(1)
        .get();
    if (q.docs.isNotEmpty) {
      final data = q.docs.first.data();
      final amount = (data['amount'] as num?)?.toDouble() ?? 0;
      final prefix =
          (data['content'] ?? '').toString().startsWith('دخل') ? 'دخل' : 'مصروف';
      await q.docs.first.reference.update({
        'category': category,
        'content': '$prefix ${amount.toStringAsFixed(0)} ج — $category',
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
      relevant = wallets;
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
      'إجمالي التمويل: ${funded.toStringAsFixed(0)} ج',
      'إجمالي المصروفات: ${expenses.toStringAsFixed(0)} ج',
      'الرصيد الحالي: ${balance.toStringAsFixed(0)} ج',
    ];

    if (top.isNotEmpty) {
      lines.add('أكبر بنود الصرف:');
      for (final e in top.take(8)) {
        lines.add('• ${e.key}: ${e.value.toStringAsFixed(0)} ج');
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
              ? 'متبقي ${remaining.toStringAsFixed(0)} ج'
              : 'تجاوز ${(-remaining).toStringAsFixed(0)} ج';
          lines.add(
              '• ${b.category}: حد ${b.periodLabel} ${b.limit.toStringAsFixed(0)} ج — صرف ${b.spent.toStringAsFixed(0)} ج — $status');
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
      'canViewReports',
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
