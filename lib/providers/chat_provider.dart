import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message_model.dart';
import '../models/transaction_model.dart';
import '../models/user_model.dart';
import '../models/family_notification_model.dart';
import '../models/wallet_model.dart';
import '../models/team_model.dart';
import '../services/database_service.dart';
import '../services/ai_service.dart';
import '../utils/category_utils.dart';

class ChatProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();
  final _uuid = const Uuid();

  List<ChatMessage> _messages = [];
  bool _loading = false;
  StreamSubscription<List<ChatMessage>>? _messagesSub;
  final Map<String, List<String>> _reportPages = {};
  final Map<String, int> _reportPageIndex = {};

  List<ChatMessage> get messages => _messages;
  bool get loading => _loading;

  bool hasMoreReport(String groupId) {
    final pages = _reportPages[groupId];
    final idx = _reportPageIndex[groupId] ?? 0;
    return pages != null && idx < pages.length;
  }

  Future<void> loadMessages(String groupId) async {
    _loading = true;
    notifyListeners();
    _messages = await _db.getMessagesSync(groupId);
    _loading = false;
    notifyListeners();
  }

  void subscribeMessages(String groupId) {
    _messagesSub?.cancel();
    _messagesSub = _db.watchMessages(groupId).listen((items) {
      _messages = items;
      _loading = false;
      notifyListeners();
    });
  }

  void stopLiveMessages() {
    _messagesSub?.cancel();
    _messagesSub = null;
  }

  Future<void> refreshMessages(String groupId) async {
    _messages = await _db.getMessagesSync(groupId);
    notifyListeners();
  }

  Future<void> clearChat(String groupId) async {
    await _db.clearMessages(groupId);
    _messages = [];
    _reportPages.remove(groupId);
    _reportPageIndex.remove(groupId);
    notifyListeners();
  }

  Future<String?> sendTeamExpenseText(
    String groupId,
    UserModel user,
    String text,
    TeamModel team,
  ) async {
    final results = AIService.parseExpenseMessages(text)
        .where((item) => item['isExpense'] == true)
        .toList();
    if (results.isEmpty) {
      return 'اكتب مصروف واضح للفريق مثل: دفعت 100 بنزين';
    }
    final totalExpense = results.fold<double>(
        0, (sum, item) => sum + (item['amount'] as double));
    final warning = _validateTeamBalance(team, totalExpense);
    if (warning != null) return warning;
    try {
      final categories = await _db.getExpenseCategoriesSync(groupId);
      final budgets = await _db.getBudgetsSync(groupId);
      final members = await _db.getMembersSync(groupId);
      for (final result in results) {
        _applyStoredMatches(
          result,
          (result['note'] as String?) ?? text,
          categories,
          budgets,
          members,
        );
      }
    } catch (_) {}
    return _sendTeamParsedEntries(groupId, user, text, results, team: team);
  }

  @override
  void dispose() {
    stopLiveMessages();
    super.dispose();
  }

  /// Returns null on success, or an Arabic warning/error message for the UI.
  Future<String?> sendTextMessage(
    String groupId,
    UserModel user,
    String text, {
    WalletModel? wallet,
    TeamModel? team,
  }) async {
    if (AIService.isNextReportCommand(text)) {
      final sent = await sendNextReportPage(groupId);
      if (!sent) {
        await _sendSystemMessage(
          groupId,
          'لا يوجد جزء تالي من التقرير حاليًا. اطلب تقريرًا جديدًا مثل: تقرير آخر أسبوع.',
        );
      }
      _messages = await _db.getMessagesSync(groupId);
      notifyListeners();
      return null;
    }

    final reportRequest = AIService.parseReportRequest(text);
    if (reportRequest != null) {
      if (!user.canViewReports) {
        final warning = '⛔ ليس لديك صلاحية عرض التقارير.';
        await _sendSystemMessage(groupId, warning);
        await refreshMessages(groupId);
        return warning;
      }
      await _db.sendMessage(ChatMessage(
        id: _uuid.v4(),
        groupId: groupId,
        senderId: user.id,
        senderName: user.name,
        senderAvatar: user.photoUrl,
        type: MessageType.text,
        content: text,
        timestamp: DateTime.now(),
      ));
      final lines = await _db.buildReportLines(
        groupId,
        days: reportRequest['days'] as int? ?? 30,
        memberName: reportRequest['memberName'] as String?,
        includeBudgets: reportRequest['includeBudgets'] as bool? ?? false,
      );
      final pages = _chunkLines(lines, 5);
      _reportPages[groupId] = pages;
      _reportPageIndex[groupId] = 0;
      await sendNextReportPage(groupId);
      _messages = await _db.getMessagesSync(groupId);
      notifyListeners();
      return null;
    }

    final aiResults = AIService.parseExpenseMessages(text);
    if (aiResults.length > 1) {
      return _sendMultipleParsedEntries(
        groupId,
        user,
        text,
        aiResults,
        wallet: wallet,
        team: team,
      );
    }

    final aiResult = aiResults.isEmpty ? null : aiResults.first;

    if (aiResult != null) {
      final isExpense = aiResult['isExpense'] as bool;
      if (isExpense) {
        try {
          final categories = await _db.getExpenseCategoriesSync(groupId);
          final budgets = await _db.getBudgetsSync(groupId);
          final members = await _db.getMembersSync(groupId);
          _applyStoredMatches(aiResult, text, categories, budgets, members);
        } catch (_) {
          // Keep the offline save path open even if matching data is not cached.
        }
      }
      final amount = aiResult['amount'] as double;

      if (isExpense && !user.canAddExpenses) {
        final warning =
            '⛔ ليس لديك صلاحية تسجيل مصروفات. اطلب من قائد العائلة تفعيلها.';
        await _sendSystemMessage(groupId, warning);
        await refreshMessages(groupId);
        return warning;
      }

      if (isExpense &&
          user.monthlyLimit > 0 &&
          user.currentSpending + amount > user.monthlyLimit) {
        final remaining = user.monthlyLimit - user.currentSpending;
        final warning =
            '⚠️ المصروف يتجاوز حدك الشهري. المتبقي لك تقريبًا ${remaining.toStringAsFixed(0)} ج.';
        await _sendSystemMessage(groupId, warning);
        await refreshMessages(groupId);
        return warning;
      }

      if (isExpense && team != null) {
        final warning = _validateTeamBalance(team, amount);
        if (warning != null) {
          await _sendSystemMessage(groupId, warning);
          await refreshMessages(groupId);
          return warning;
        }
      }
    }

    if (aiResult != null && team != null && aiResult['isExpense'] == true) {
      await _sendTeamParsedEntries(
        groupId,
        user,
        text,
        [aiResult],
        wallet: wallet,
        team: team,
      );
      return null;
    }

    final transactionId = aiResult != null ? _uuid.v4() : null;
    final message = ChatMessage(
      id: _uuid.v4(),
      groupId: groupId,
      senderId: user.id,
      senderName: user.name,
      senderAvatar: user.photoUrl,
      type: aiResult != null ? MessageType.expense : MessageType.text,
      content: aiResult != null ? _formatExpenseText(aiResult) : text,
      amount: aiResult?['amount'] as double?,
      category: aiResult?['category'] as String?,
      transactionId: transactionId,
      timestamp: DateTime.now(),
    );
    await _db.sendMessage(message);

    if (aiResult != null && transactionId != null) {
      final transactionUserId =
          (aiResult['targetUserId'] as String?) ?? user.id;
      final transactionUserName =
          (aiResult['targetUserName'] as String?) ?? user.name;
      final isExpense = aiResult['isExpense'] as bool;
      final amount = aiResult['amount'] as double;
      final transaction = TransactionModel(
        id: transactionId,
        groupId: groupId,
        userId: transactionUserId,
        userName: transactionUserName,
        amount: amount,
        category: aiResult['category'] as String,
        isExpense: isExpense,
        note: aiResult['note'] as String?,
        walletId: isExpense ? wallet?.id : null,
        walletName: isExpense ? wallet?.name : null,
      );
      await _db.addTransaction(transaction);
      if (isExpense && wallet != null) {
        await _db.applyWalletDelta(groupId, wallet.id, -amount);
      }

      final category = aiResult['category'] as String;
      final title = isExpense ? 'مصروف جديد' : 'دخل جديد';
      final body =
          '${transactionUserName}: ${amount.toStringAsFixed(0)} ج — $category';
      await _db.addFamilyNotification(FamilyNotificationModel(
        id: _uuid.v4(),
        groupId: groupId,
        title: title,
        body: body,
        actorId: user.id,
        actorName: user.name,
        timestamp: DateTime.now(),
      ));

      try {
        final savedTxns = await _db.getTransactionsSync(groupId);
        final monthExpenses = savedTxns
            .where((t) =>
                t.isExpense &&
                t.date.year == DateTime.now().year &&
                t.date.month == DateTime.now().month)
            .fold<double>(0.0, (sum, t) => sum + t.amount);
        await _sendSystemMessage(
          groupId,
          '✅ تم حفظ المصروف في سجل الحسابات الحقيقي:\n${_formatExpenseText(aiResult)}\nعدد العمليات المحفوظة الآن: ${savedTxns.length}\nإجمالي مصروفات الشهر: ${monthExpenses.toStringAsFixed(0)} ج',
        );
      } catch (_) {
        await _sendSystemMessage(
          groupId,
          'تم حفظ المصروف على هذا الجهاز، وسيظهر لباقي العائلة تلقائيًا عند رجوع الإنترنت.',
        );
      }
    }

    try {
      _messages = await _db.getMessagesSync(groupId);
    } catch (_) {}
    notifyListeners();
    return null;
  }

  Future<String?> deleteExpenseEntry(
      String groupId, UserModel user, ChatMessage message) async {
    if (message.transactionId == null || message.transactionId!.isEmpty) {
      return 'لا أستطيع حذف هذا الإدخال لأنه غير مرتبط بمصروف محفوظ.';
    }
    if (!(user.isAdmin || message.senderId == user.id)) {
      return '⛔ لا يمكنك حذف إدخال مسجل بواسطة عضو آخر إلا إذا كنت قائد العائلة.';
    }
    if (message.isDeleted) return 'هذا الإدخال محذوف بالفعل.';

    final deleted =
        await _db.deleteTransaction(groupId, message.transactionId!);
    if (deleted == null)
      return 'لم أجد المصروف في السجلات. ربما تم حذفه من قبل.';
    if (deleted.isExpense &&
        deleted.walletId != null &&
        deleted.walletId!.isNotEmpty) {
      await _db.applyWalletDelta(groupId, deleted.walletId!, deleted.amount);
    }

    await _db.markTransactionMessageDeleted(groupId, message.transactionId!);
    await _db.addFamilyNotification(FamilyNotificationModel(
      id: _uuid.v4(),
      groupId: groupId,
      title: deleted.isExpense ? 'حذف مصروف' : 'حذف دخل',
      body:
          '${user.name} حذف ${deleted.amount.toStringAsFixed(0)} ج — ${deleted.category}',
      actorId: user.id,
      actorName: user.name,
      timestamp: DateTime.now(),
    ));
    await _sendSystemMessage(
      groupId,
      '🗑️ تم حذف الإدخال وإرجاع أثره إلى الميزانية: ${deleted.amount.toStringAsFixed(0)} ج — ${deleted.category}',
    );
    _messages = await _db.getMessagesSync(groupId);
    notifyListeners();
    return null;
  }

  Future<bool> sendNextReportPage(String groupId) async {
    final pages = _reportPages[groupId];
    final idx = _reportPageIndex[groupId] ?? 0;
    if (pages == null || idx >= pages.length) return false;
    final pageNo = idx + 1;
    final total = pages.length;
    final hasNext = pageNo < total;
    final content =
        '${pages[idx]}\n\nصفحة $pageNo من $total${hasNext ? '\nاكتب "التالي" لعرض باقي التقرير.' : ''}';
    _reportPageIndex[groupId] = idx + 1;
    await _sendSystemMessage(groupId, content);
    _messages = await _db.getMessagesSync(groupId);
    notifyListeners();
    return true;
  }

  List<String> _chunkLines(List<String> lines, int size) {
    final pages = <String>[];
    for (var i = 0; i < lines.length; i += size) {
      pages.add(lines.skip(i).take(size).join('\n'));
    }
    return pages.isEmpty ? ['لا توجد بيانات كافية للتقرير.'] : pages;
  }

  Future<void> _sendSystemMessage(String groupId, String content) async {
    final systemMsg = ChatMessage(
      id: _uuid.v4(),
      groupId: groupId,
      senderId: 'system',
      senderName: 'مساعد العائلة',
      type: MessageType.system,
      content: content,
      timestamp: DateTime.now(),
    );
    await _db.sendMessage(systemMsg);
  }

  Future<String?> _sendMultipleParsedEntries(String groupId, UserModel user,
      String originalText, List<Map<String, dynamic>> results,
      {WalletModel? wallet, TeamModel? team}) async {
    final hasExpense = results.any((r) => r['isExpense'] == true);
    if (hasExpense && !user.canAddExpenses) {
      final warning =
          '⛔ ليس لديك صلاحية تسجيل مصروفات. اطلب من قائد العائلة تفعيلها.';
      await _sendSystemMessage(groupId, warning);
      await refreshMessages(groupId);
      return warning;
    }

    try {
      final categories = await _db.getExpenseCategoriesSync(groupId);
      final budgets = await _db.getBudgetsSync(groupId);
      final members = await _db.getMembersSync(groupId);
      for (final result in results) {
        if (result['isExpense'] == true) {
          _applyStoredMatches(
            result,
            (result['note'] as String?) ?? originalText,
            categories,
            budgets,
            members,
          );
        }
      }
    } catch (_) {
      // Keep the offline save path open even if matching data is not cached.
    }

    final totalExpense = results
        .where((r) => r['isExpense'] == true)
        .fold<double>(0, (sum, r) => sum + (r['amount'] as double));
    if (hasExpense &&
        user.monthlyLimit > 0 &&
        user.currentSpending + totalExpense > user.monthlyLimit) {
      final remaining = user.monthlyLimit - user.currentSpending;
      final warning =
          '⚠️ المصروفات تتجاوز حدك الشهري. المتبقي لك تقريبًا ${remaining.toStringAsFixed(0)} ج.';
      await _sendSystemMessage(groupId, warning);
      await refreshMessages(groupId);
      return warning;
    }

    if (team != null && hasExpense) {
      final warning = _validateTeamBalance(team, totalExpense);
      if (warning != null) {
        await _sendSystemMessage(groupId, warning);
        await refreshMessages(groupId);
        return warning;
      }
      return _sendTeamParsedEntries(
        groupId,
        user,
        originalText,
        results,
        wallet: wallet,
        team: team,
      );
    }

    for (final result in results) {
      final transactionId = _uuid.v4();
      final transactionUserId = (result['targetUserId'] as String?) ?? user.id;
      final transactionUserName =
          (result['targetUserName'] as String?) ?? user.name;
      final message = ChatMessage(
        id: _uuid.v4(),
        groupId: groupId,
        senderId: user.id,
        senderName: user.name,
        senderAvatar: user.photoUrl,
        type: MessageType.expense,
        content: _formatExpenseText(result),
        amount: result['amount'] as double,
        category: result['category'] as String,
        transactionId: transactionId,
        timestamp: DateTime.now(),
      );
      await _db.sendMessage(message);
      final isExpense = result['isExpense'] as bool;
      final amount = result['amount'] as double;
      await _db.addTransaction(TransactionModel(
        id: transactionId,
        groupId: groupId,
        userId: transactionUserId,
        userName: transactionUserName,
        amount: amount,
        category: result['category'] as String,
        isExpense: isExpense,
        note: result['note'] as String?,
        walletId: isExpense ? wallet?.id : null,
        walletName: isExpense ? wallet?.name : null,
      ));
      if (isExpense && wallet != null) {
        await _db.applyWalletDelta(groupId, wallet.id, -amount);
      }
    }

    await _db.addFamilyNotification(FamilyNotificationModel(
      id: _uuid.v4(),
      groupId: groupId,
      title: 'بنود جديدة',
      body: 'تم تسجيل ${results.length} بنود من ${user.name}',
      actorId: user.id,
      actorName: user.name,
      timestamp: DateTime.now(),
    ));

    final total = results
        .where((r) => r['isExpense'] == true)
        .fold<double>(0, (sum, r) => sum + (r['amount'] as double));
    await _sendSystemMessage(
      groupId,
      'تم تسجيل ${results.length} مصروفات بإجمالي ${total.toStringAsFixed(total.truncateToDouble() == total ? 0 : 2)} ج',
    );

    _messages = await _db.getMessagesSync(groupId);
    notifyListeners();
    return null;
  }

  String? _validateTeamBalance(TeamModel team, double newExpense) {
    if (team.balance <= 0) {
      return '⚠️ رصيد فريق ${team.name} غير كافي. زوّد رصيد الفريق قبل تسجيل المصروف.';
    }
    if (newExpense <= team.balance) return null;
    return '⚠️ رصيد فريق ${team.name} غير كافي. المتاح ${team.balance.toStringAsFixed(0)} ج والمصروف ${newExpense.toStringAsFixed(0)} ج.';
  }

  Future<String?> _sendTeamParsedEntries(
    String groupId,
    UserModel user,
    String originalText,
    List<Map<String, dynamic>> results, {
    required TeamModel team,
    WalletModel? wallet,
  }) async {
    var savedCount = 0;
    var total = 0.0;
    for (final result in results.where((r) => r['isExpense'] == true)) {
      final transactionId = _uuid.v4();
      final amount = result['amount'] as double;
      final transaction = TransactionModel(
        id: transactionId,
        groupId: groupId,
        userId: user.id,
        userName: user.name,
        amount: amount,
        category: result['category'] as String,
        isExpense: true,
        note: result['note'] as String? ?? originalText,
        walletId: wallet?.id,
        walletName: wallet?.name,
        teamId: team.id,
        teamName: team.name,
      );
      await _db.addTransaction(transaction);
      await _db.applyTeamBalanceDelta(groupId, team.id, -amount);
      if (wallet != null) {
        await _db.applyWalletDelta(groupId, wallet.id, -amount);
      }
      savedCount++;
      total += amount;
    }

    final recipients = <String>{
      team.ownerId,
      user.id,
      ...team.memberIds,
    }.where((id) => id.trim().isNotEmpty).toList();
    await _db.addFamilyNotification(FamilyNotificationModel(
      id: _uuid.v4(),
      groupId: groupId,
      title: 'مصروف فريق ${team.name}',
      body:
          '${user.name}: ${total.toStringAsFixed(0)} ج في $savedCount بند. اضغط على الفرق لمراجعة التفاصيل.',
      actorId: user.id,
      actorName: user.name,
      timestamp: DateTime.now(),
      targetUserIds: recipients,
    ));

    notifyListeners();
    return null;
  }

  void _applyStoredMatches(
    Map<String, dynamic> aiResult,
    String text,
    List<String> categories,
    List<dynamic> budgets,
    List<UserModel> members,
  ) {
    final candidates = <String>[];
    candidates.addAll(categories);
    candidates.addAll(budgets.map((b) => b.category));
    for (final member in members) {
      final name = member.name.trim();
      if (name.isEmpty) continue;
      candidates.add(name);
      candidates.add('مصروف $name');
      candidates.add('حساب $name');
    }
    final hardMatchedCategory =
        _hardMatchStoredBudgetOrCategory(text, categories, budgets, members);
    if (hardMatchedCategory != null) {
      aiResult['category'] = hardMatchedCategory;
    } else {
      final matchedCategory =
          AIService.matchExpenseCategoryFromList(text, candidates);
      if (matchedCategory != null) {
        final normalizedMatch =
            _normalizeMatchedBudgetName(matchedCategory, categories, budgets);
        aiResult['category'] = normalizedMatch ?? matchedCategory;
      }
    }
    final matchedMember = _hardMatchMemberFromText(text, members) ??
        _matchMemberFromText(text, members);
    if (matchedMember != null) {
      aiResult['targetUserId'] = matchedMember.id;
      aiResult['targetUserName'] = matchedMember.name;
      final memberBudgetMatch = _normalizeMatchedBudgetName(
              matchedMember.name, categories, budgets) ??
          _hardMatchStoredBudgetOrCategory(
              matchedMember.name, categories, budgets, members);
      if (memberBudgetMatch != null) aiResult['category'] = memberBudgetMatch;
    }
  }

  String? _hardMatchStoredBudgetOrCategory(
    String text,
    List<String> categories,
    List<dynamic> budgets,
    List<UserModel> members,
  ) {
    final names = <String>[];

    // Budgets first because these are the rows that must update in Settings.
    for (final b in budgets) {
      try {
        final category = (b.category as String).trim();
        if (category.isNotEmpty) names.add(category);
      } catch (_) {}
    }

    // Then user-created categories, then helper names for members.
    names.addAll(categories.where((c) => c.trim().isNotEmpty));
    for (final member in members) {
      final name = member.name.trim();
      if (name.isEmpty) continue;
      names.add(name);
      names.add('مصروف $name');
      names.add('مصاريف $name');
      names.add('حساب $name');
    }

    final unique = <String>[];
    final seen = <String>{};
    for (final name in names) {
      final key = CategoryUtils.key(name);
      if (key.isEmpty || key == CategoryUtils.key('أخرى') || seen.contains(key))
        continue;
      seen.add(key);
      unique.add(name);
    }

    // Prefer custom/narrow names over the default app categories.
    unique.sort((a, b) {
      final customA = AppConstantsLike.isDefaultExpenseCategory(a) ? 0 : 1;
      final customB = AppConstantsLike.isDefaultExpenseCategory(b) ? 0 : 1;
      if (customA != customB) return customB.compareTo(customA);
      return CategoryUtils.key(b).length.compareTo(CategoryUtils.key(a).length);
    });

    for (final name in unique) {
      if (_textContainsName(text, name)) {
        final stored = _normalizeMatchedBudgetName(name, categories, budgets);
        return stored ?? name;
      }
    }
    return null;
  }

  UserModel? _hardMatchMemberFromText(String text, List<UserModel> members) {
    final sorted = members.where((m) => m.name.trim().isNotEmpty).toList()
      ..sort((a, b) => CategoryUtils.key(b.name)
          .length
          .compareTo(CategoryUtils.key(a.name).length));
    for (final member in sorted) {
      final name = member.name.trim();
      if (_textContainsName(text, name) ||
          _textContainsName(text, 'مصروف $name') ||
          _textContainsName(text, 'مصاريف $name') ||
          _textContainsName(text, 'حساب $name')) {
        return member;
      }
    }
    return null;
  }

  bool _textContainsName(String text, String name) {
    final nameKey = CategoryUtils.key(name);
    if (nameKey.length < 2 || nameKey == CategoryUtils.key('أخرى'))
      return false;

    final textKey = CategoryUtils.key(text);
    if (textKey.contains(nameKey)) return true;

    final textTokens =
        CategoryUtils.meaningfulTokens(text).map(CategoryUtils.key).toSet();
    final nameTokens = CategoryUtils.meaningfulTokens(name)
        .map(CategoryUtils.key)
        .where((t) =>
            t.length >= 2 &&
            t != CategoryUtils.key('مصروف') &&
            t != CategoryUtils.key('مصاريف'))
        .toList();
    if (nameTokens.isEmpty) return false;
    return nameTokens
        .any((token) => textTokens.contains(token) || textKey.contains(token));
  }

  UserModel? _matchMemberFromText(String text, List<UserModel> members) {
    final sorted = members.where((m) => m.name.trim().isNotEmpty).toList()
      ..sort((a, b) => b.name.length.compareTo(a.name.length));
    for (final member in sorted) {
      final name = member.name.trim();
      if (AIService.matchExpenseCategoryFromList(
              text, [name, 'مصروف $name', 'حساب $name']) !=
          null) {
        return member;
      }
    }
    return null;
  }

  String? _normalizeMatchedBudgetName(
      String matchedCategory, List<String> categories, List<dynamic> budgets) {
    final names = <String>[];
    names.addAll(categories);
    for (final b in budgets) {
      try {
        final c = b.category as String;
        if (c.trim().isNotEmpty) names.add(c);
      } catch (_) {}
    }
    return AIService.matchExpenseCategoryFromList(matchedCategory, names);
  }

  String _formatExpenseText(Map<String, dynamic> result) {
    final amount = result['amount'] as double;
    final category = result['category'] as String;
    final isExpense = result['isExpense'] as bool;
    final prefix = isExpense ? 'مصروف' : 'دخل';
    return '$prefix ${amount.toStringAsFixed(amount.truncateToDouble() == amount ? 0 : 2)} ج — $category';
  }
}

class AppConstantsLike {
  static bool isDefaultExpenseCategory(String value) {
    final key = CategoryUtils.key(value);
    const defaults = [
      'أكل ومشروبات',
      'مواصلات',
      'إيجار',
      'كهرباء',
      'مياه',
      'غاز',
      'إنترنت',
      'اتصالات',
      'تعليم',
      'صحة',
      'ملابس',
      'ترفيه',
      'هدايا',
      'أخرى',
    ];
    return defaults.any((d) => CategoryUtils.key(d) == key);
  }
}
