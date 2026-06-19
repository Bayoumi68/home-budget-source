import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';
import '../models/chat_message_model.dart';
import '../models/transaction_model.dart';
import '../models/budget_model.dart';
import '../models/group_model.dart';
import '../models/family_notification_model.dart';
import '../config/constants.dart';
import '../utils/category_utils.dart';

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
class DatabaseService {
  static const _activeUserKey = 'active_user';
  static const _activeGroupKey = 'active_group';
  static const _sessionVersionKey = 'active_app_version';

  SharedPreferences? _prefs;
  FirebaseFirestore get _fs => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _families =>
      _fs.collection('families');
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

  Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  String _docSafeId(String value) {
    final key = CategoryUtils.key(value);
    return key.isEmpty ? DateTime.now().millisecondsSinceEpoch.toString() : key;
  }

  // ─── Session ───
  Future<void> saveActiveSession(UserModel user, GroupModel group) async {
    await _ensurePrefs();
    await _prefs?.setString(_activeUserKey, _encode(user.toMap()));
    await _prefs?.setString(_activeGroupKey, _encode(group.toMap()));
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

  Future<void> clearActiveSession() async {
    await _ensurePrefs();
    await _prefs?.remove(_activeUserKey);
    await _prefs?.remove(_activeGroupKey);
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
  Future<GroupModel> createGroup(
    String name,
    String adminId,
    String adminName, {
    String? adminPhone,
  }) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final inviteCode = id.substring(id.length - 6).toUpperCase();
    final admin = UserModel(
      id: adminId,
      name: adminName,
      phone: adminPhone,
      isAdmin: true,
      canAddExpenses: true,
      canViewReports: true,
      canManageMembers: true,
      canManageBudgets: true,
    );
    final group = GroupModel(
      id: id,
      name: name,
      adminId: adminId,
      members: [admin],
      inviteCode: inviteCode,
    );
    await _families.doc(id).set({
      ...group.toMap(),
      'appVersion': AppConstants.appVersion,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await _members(id).doc(admin.id).set({
      ...admin.toMap(),
      'createdAt': DateTime.now().toIso8601String(),
    });
    await writeDiagnostic('create_group', groupId: id, userId: admin.id);
    return group;
  }

  Future<GroupModel?> getGroupByInvite(String code) async {
    final q = await _families
        .where('inviteCode', isEqualTo: code.trim().toUpperCase())
        .limit(1)
        .get();
    if (q.docs.isEmpty) return null;
    return GroupModel.fromMap(q.docs.first.data());
  }

  Future<GroupModel?> getGroupById(String groupId) async {
    final doc = await _families.doc(groupId).get();
    if (!doc.exists || doc.data() == null) return null;
    return GroupModel.fromMap(doc.data()!);
  }

  Future<void> joinGroup(String groupId, UserModel user) async {
    final normalizedPhone = user.phone?.trim();
    final prepared = normalizedPhone == null || normalizedPhone.isEmpty
        ? null
        : await getMemberByPhone(groupId, normalizedPhone);
    final toSave = prepared == null
        ? user
        : prepared.copyWith(
            id: user.id,
            name: user.name.isEmpty ? prepared.name : user.name,
            phone: user.phone ?? prepared.phone);
    await _members(groupId)
        .doc(toSave.id)
        .set(toSave.toMap(), SetOptions(merge: true));
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
    final normalized = phone.trim();
    if (normalized.isEmpty) return null;
    final q = await _members(groupId)
        .where('phone', isEqualTo: normalized)
        .limit(1)
        .get();
    if (q.docs.isEmpty) return null;
    return UserModel.fromMap(q.docs.first.data());
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
  Future<List<TransactionModel>> getTransactionsSync(String groupId) async {
    final q = await _transactions(groupId)
        .orderBy('date', descending: true)
        .limit(1000)
        .get();
    return q.docs.map((d) => TransactionModel.fromMap(d.data())).toList();
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

  // ─── Expense Categories + Budgets ───
  Future<List<String>> getExpenseCategoriesSync(String groupId) async {
    final q = await _categories(groupId).orderBy('createdAt').get();
    final bq = await _budgets(groupId).get();
    final saved = q.docs
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
      if (key.isEmpty || seen.contains(key)) continue;
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

  Future<List<BudgetModel>> getBudgetsSync(String groupId) async {
    final q = await _budgets(groupId).get();
    final txns = await getTransactionsSync(groupId);
    final existing = q.docs.map((d) => BudgetModel.fromMap(d.data())).toList();
    existing.sort((a, b) => a.category.compareTo(b.category));
    return existing
        .map((b) => b.copyWith(spent: _spentForCategory(txns, b.category)))
        .toList();
  }

  Future<void> setBudget(String groupId, String category, double limit) async {
    final clean = category.trim();
    if (clean.isEmpty) return;
    await _ensureCategoryStored(groupId, clean);
    final txns = await getTransactionsSync(groupId);
    final spent = _spentForCategory(txns, clean);
    await _budgets(groupId).doc(_docSafeId(clean)).set({
      'category': clean,
      'limit': limit,
      'spent': spent,
      'monthKey': _monthKey(),
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  Future<void> _ensureCategoryStored(String groupId, String category) async {
    final clean = category.trim();
    if (clean.isEmpty) return;
    final key = _categoryKey(clean);
    if (AppConstants.expenseCategories.any((name) => _categoryKey(name) == key))
      return;
    await _categories(groupId).doc(_docSafeId(clean)).set({
      'name': clean,
      'createdAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
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
  String _monthKey([DateTime? date]) {
    final d = date ?? DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
  }

  bool _transactionMatchesBudget(TransactionModel t, String category) {
    if (!t.isExpense || !CategoryUtils.isThisMonth(t.date)) return false;
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

  double _spentForCategory(List<TransactionModel> txns, String category) {
    return txns
        .where((t) => _transactionMatchesBudget(t, category))
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
      final spent = _spentForCategory(txns, category);
      batch.set(
          doc.reference,
          {
            ...data,
            'spent': spent,
            'monthKey': _monthKey(),
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
    final income = filtered
        .where((t) => !t.isExpense)
        .fold<double>(0.0, (sum, t) => sum + t.amount);
    final byCategory = <String, double>{};
    for (final t in filtered.where((t) => t.isExpense)) {
      final display = _resolvedDisplayCategory(t, categories);
      byCategory[display] = (byCategory[display] ?? 0) + t.amount;
    }
    final top = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
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
      'إجمالي الدخل: ${income.toStringAsFixed(0)} ج',
      'إجمالي المصروفات: ${expenses.toStringAsFixed(0)} ج',
      'الصافي: ${(income - expenses).toStringAsFixed(0)} ج',
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
              '• ${b.category}: حد ${b.limit.toStringAsFixed(0)} ج — صرف ${b.spent.toStringAsFixed(0)} ج — $status');
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
      'canManageBudgets'
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
