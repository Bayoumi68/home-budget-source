import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import '../models/category_model.dart';
import '../models/chat_message_model.dart';
import '../models/resolved_expense.dart';
import '../models/transaction_model.dart';
import '../models/user_model.dart';
import '../models/family_notification_model.dart';
import '../models/wallet_model.dart';
import '../models/wallet_entry_model.dart';
import '../models/team_model.dart';
import '../services/database_service.dart';
import '../services/ai_service.dart';
import '../utils/category_utils.dart';
import '../utils/expense_description.dart';

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

  /// Thin wrapper: resolve, then commit straight to the team (no confirm
  /// dialog here — team_member_home_screen.dart shows one before calling this
  /// with the user's possibly-edited categories via commitResolvedExpenses).
  Future<String?> sendTeamExpenseText(
    String groupId,
    UserModel user,
    String text,
    TeamModel team,
  ) async {
    final categoryModels = await _db.getCategoriesSync(groupId);
    final resolved = (await resolveExpenseMessages(groupId, text, user,
            categories: categoryModels))
        .where((r) => r.isExpense)
        .toList();
    if (resolved.isEmpty) {
      return 'اكتب مصروف واضح للفريق مثل: دفعت 100 بنزين';
    }
    final totalExpense =
        resolved.fold<double>(0, (sum, r) => sum + r.amount);
    // Teams have no pot: the member spends from their OWN wallet.
    WalletModel? wallet;
    try {
      for (final w in await _db.getWalletsSync(groupId)) {
        if (w.isMemberWallet && w.ownerId == user.id) {
          wallet = w;
          break;
        }
      }
    } catch (_) {}
    if (wallet != null && totalExpense > wallet.balance + 0.005) {
      return 'الرصيد غير كافٍ في محفظتك. المتاح ${wallet.balance.toStringAsFixed(0)} ج.';
    }
    return commitResolvedExpenses(groupId, user, text, resolved,
        wallet: wallet, team: team);
  }

  /// Parses [text] into candidate expenses/income and runs the SAME
  /// hard-match-against-live-data step ([_applyStoredMatches]) that saving
  /// uses — with NO writes. Called by both the pre-send confirm dialog and the
  /// actual commit, so what the user confirms is guaranteed to be what saves.
  Future<List<ResolvedExpense>> resolveExpenseMessages(
    String groupId,
    String text,
    UserModel user, {
    required List<CategoryModel> categories,
  }) async {
    final aiResults = AIService.parseExpenseMessages(text,
        categories: categories);
    if (aiResults.isEmpty) return const [];

    try {
      final categoryNames =
          categories.where((c) => !c.isIncome).map((c) => c.name).toList();
      final budgets = await _db.getBudgetsSync(groupId);
      final members = await _db.getMembersSync(groupId);
      final learned = await _db.getLearnedKeywordsSync(groupId);
      for (final result in aiResults) {
        if (result['isExpense'] == true) {
          _applyStoredMatches(
            result,
            (result['note'] as String?) ?? text,
            categoryNames,
            budgets,
            members,
            learned: learned,
          );
        }
      }
    } catch (_) {
      // Keep the offline save path open even if matching data is not cached.
    }

    // Soft red flag (not a block): the combined total across every resolved
    // item in this message decides over-cap, matching the pre-refactor logic.
    final totalExpense = aiResults
        .where((r) => r['isExpense'] == true)
        .fold<double>(0, (sum, r) => sum + (r['amount'] as double));
    final overCapAll = user.monthlyLimit > 0 &&
        user.currentSpending + totalExpense > user.monthlyLimit;

    return aiResults.map((r) {
      final categoryName = r['category'] as String;
      final match = categories.firstWhere(
        (c) => c.name == categoryName,
        orElse: () => CategoryModel(id: '', name: categoryName),
      );
      return ResolvedExpense(
        amount: r['amount'] as double,
        isExpense: r['isExpense'] as bool,
        note: (r['note'] as String?) ?? text,
        category: categoryName,
        categoryId: match.id.isEmpty ? null : match.id,
        overCap: (r['isExpense'] == true) && overCapAll,
        targetUserId: r['targetUserId'] as String?,
        targetUserName: r['targetUserName'] as String?,
      );
    }).toList();
  }

  /// Writes already-resolved (and possibly user-edited) expenses/income:
  /// permission check, message + transaction + wallet-ledger debit,
  /// notification, and the confirmation system message — for 1..N items,
  /// either into the family chat feed or (if [team] is set) a team's own
  /// transactions with no chat-feed message.
  Future<String?> commitResolvedExpenses(
    String groupId,
    UserModel user,
    String originalText,
    List<ResolvedExpense> items, {
    WalletModel? wallet,
    TeamModel? team,
    String? targetUserId,
    ChatMessage? replyTo,
  }) async {
    if (items.isEmpty) return null;
    final hasExpense = items.any((r) => r.isExpense);
    if (hasExpense && !user.canAddExpenses) {
      final warning =
          '⛔ ليس لديك صلاحية تسجيل مصروفات. اطلب من قائد العائلة تفعيلها.';
      await _sendSystemMessage(groupId, warning);
      await refreshMessages(groupId);
      return warning;
    }

    if (team != null && hasExpense) {
      return _commitTeamResolvedExpenses(groupId, user, originalText, items,
          wallet: wallet, team: team);
    }

    final isSingle = items.length == 1;
    for (final item in items) {
      final transactionId = _uuid.v4();
      final description = buildExpenseDescription(
        rawText: item.note,
        categoryName: item.category,
      );
      final message = ChatMessage(
        id: _uuid.v4(),
        groupId: groupId,
        senderId: user.id,
        senderName: user.name,
        senderAvatar: user.photoUrl,
        type: MessageType.expense,
        content: buildExpenseBubbleContent(
          isExpense: item.isExpense,
          amount: item.amount,
          rawText: item.note,
        ),
        amount: item.amount,
        category: item.category,
        transactionId: transactionId,
        timestamp: DateTime.now(),
        overCap: item.overCap,
        targetUserId: isSingle ? targetUserId : null,
        replyToId: isSingle ? replyTo?.id : null,
        replyToSender: isSingle ? replyTo?.senderName : null,
        replyToText: isSingle && replyTo != null ? _replyPreview(replyTo) : null,
      );
      await _db.sendMessage(message);

      final transactionUserId = item.targetUserId ?? user.id;
      final transactionUserName = item.targetUserName ?? user.name;
      await _db.recordTransaction(
        TransactionModel(
          id: transactionId,
          groupId: groupId,
          userId: transactionUserId,
          userName: transactionUserName,
          amount: item.amount,
          category: item.category,
          categoryId: item.categoryId,
          isExpense: item.isExpense,
          note: item.note,
          walletId: item.isExpense ? wallet?.id : null,
          walletName: item.isExpense ? wallet?.name : null,
          overCap: item.overCap,
          description: description,
        ),
        wallet: item.isExpense ? wallet : null,
        byName: user.name,
        byPhone: user.phone,
      );
    }

    if (isSingle) {
      final item = items.first;
      final targetName = item.targetUserName ?? user.name;
      final title = item.isExpense ? 'مصروف جديد' : 'دخل جديد';
      final body =
          '$targetName: ${item.amount.toStringAsFixed(0)} ج — ${item.category}';
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
            .where((t) => t.isExpense && CategoryUtils.isThisMonth(t.date))
            .fold<double>(0.0, (sum, t) => sum + t.amount);
        await _sendSystemMessage(
          groupId,
          '✅ تم حفظ المصروف في سجل الحسابات الحقيقي:\n${_formatResolvedText(item)}\nعدد العمليات المحفوظة الآن: ${savedTxns.length}\nإجمالي مصروفات الشهر: ${monthExpenses.toStringAsFixed(0)} ج',
        );
      } catch (_) {
        await _sendSystemMessage(
          groupId,
          'تم حفظ المصروف على هذا الجهاز، وسيظهر لباقي العائلة تلقائيًا عند رجوع الإنترنت.',
        );
      }
    } else {
      await _db.addFamilyNotification(FamilyNotificationModel(
        id: _uuid.v4(),
        groupId: groupId,
        title: 'بنود جديدة',
        body: 'تم تسجيل ${items.length} بنود من ${user.name}',
        actorId: user.id,
        actorName: user.name,
        timestamp: DateTime.now(),
      ));
      final total =
          items.where((r) => r.isExpense).fold<double>(0, (sum, r) => sum + r.amount);
      await _sendSystemMessage(
        groupId,
        'تم تسجيل ${items.length} مصروفات بإجمالي ${total.toStringAsFixed(total.truncateToDouble() == total ? 0 : 2)} ج',
      );
    }

    try {
      _messages = await _db.getMessagesSync(groupId);
    } catch (_) {}
    notifyListeners();
    return null;
  }

  /// Team-branch of [commitResolvedExpenses]: transactions only, no chat-feed
  /// message (teams have their own transaction list, not the family feed).
  Future<String?> _commitTeamResolvedExpenses(
    String groupId,
    UserModel user,
    String originalText,
    List<ResolvedExpense> items, {
    required TeamModel team,
    WalletModel? wallet,
  }) async {
    var savedCount = 0;
    var total = 0.0;
    for (final item in items.where((r) => r.isExpense)) {
      final transactionId = _uuid.v4();
      final description = buildExpenseDescription(
        rawText: item.note,
        categoryName: item.category,
      );
      await _db.recordTransaction(
        TransactionModel(
          id: transactionId,
          groupId: groupId,
          userId: user.id,
          userName: user.name,
          amount: item.amount,
          category: item.category,
          categoryId: item.categoryId,
          isExpense: true,
          note: item.note,
          walletId: wallet?.id,
          walletName: wallet?.name,
          teamId: team.id,
          teamName: team.name,
          description: description,
        ),
        wallet: wallet,
        byName: user.name,
        byPhone: user.phone,
      );
      savedCount++;
      total += item.amount;
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

  String _formatResolvedText(ResolvedExpense item) {
    final prefix = item.isExpense ? 'مصروف' : 'دخل';
    final amountText = item.amount.truncateToDouble() == item.amount
        ? item.amount.toStringAsFixed(0)
        : item.amount.toStringAsFixed(2);
    return '$prefix $amountText ج — ${item.category}';
  }

  @override
  void dispose() {
    stopLiveMessages();
    super.dispose();
  }

  /// Returns null on success, or an Arabic warning/error message for the UI.
  /// Short snippet of the message being replied to, shown in the reply quote.
  String _replyPreview(ChatMessage m) {
    if (m.type == MessageType.expense && m.amount != null) {
      return '${m.category ?? 'مصروف'}: ${m.amount!.toStringAsFixed(0)} ج';
    }
    final c = m.content.trim();
    return c.length > 80 ? '${c.substring(0, 80)}…' : c;
  }

  Future<String?> sendTextMessage(
    String groupId,
    UserModel user,
    String text, {
    WalletModel? wallet,
    TeamModel? team,
    String? targetUserId,
    ChatMessage? replyTo,
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

    // A "cash into wallet" message is a top-up, handled by the chat screen
    // (it picks the wallet). If we ever reach here, store it as plain text so
    // it is never mis-booked as an expense.
    if (AIService.parseWalletInjection(text) != null) {
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
      await refreshMessages(groupId);
      return null;
    }

    // Thin wrapper over resolve+commit (no confirm dialog here — chat_screen.dart
    // shows the mandatory confirm dialog itself and calls commitResolvedExpenses
    // directly for its own send flow; this path stays as a self-contained
    // fallback for any other caller of sendTextMessage).
    final categoryModels = await _db.getCategoriesSync(groupId);
    final resolved = await resolveExpenseMessages(groupId, text, user,
        categories: categoryModels);
    if (resolved.isEmpty) {
      await _db.sendMessage(ChatMessage(
        id: _uuid.v4(),
        groupId: groupId,
        senderId: user.id,
        senderName: user.name,
        senderAvatar: user.photoUrl,
        type: MessageType.text,
        content: text,
        timestamp: DateTime.now(),
        targetUserId: targetUserId,
        replyToId: replyTo?.id,
        replyToSender: replyTo?.senderName,
        replyToText: replyTo == null ? null : _replyPreview(replyTo),
      ));
      try {
        _messages = await _db.getMessagesSync(groupId);
      } catch (_) {}
      notifyListeners();
      return null;
    }
    return commitResolvedExpenses(groupId, user, text, resolved,
        wallet: wallet, team: team, targetUserId: targetUserId, replyTo: replyTo);
  }

  /// Cash into a wallet (a top-up): DR the wallet ledger and update its
  /// balance. It is NOT recorded as income. Returns an Arabic warning, or null.
  Future<String?> injectToWallet(
    String groupId,
    UserModel user,
    double amount,
    WalletModel wallet, {
    String? note,
  }) async {
    if (!user.isAdmin) {
      const warning = '⛔ إضافة الأموال من صلاحية القائد فقط.';
      await _sendSystemMessage(groupId, warning);
      await refreshMessages(groupId);
      return warning;
    }
    try {
      final newBalance = await _db.postWalletEntry(
        groupId,
        wallet.id,
        direction: 'DR',
        amount: amount,
        source: 'injection',
        note: note,
        byName: user.name,
        byPhone: user.phone,
      );
      await _sendSystemMessage(
        groupId,
        '💰 إيداع نقدي: ${amount.toStringAsFixed(0)} ج في ${wallet.name}.\n'
        'رصيد المحفظة الآن: ${newBalance.toStringAsFixed(0)} ج.',
      );
      await refreshMessages(groupId);
      return null;
    } catch (_) {
      const warning = 'تعذر تنفيذ الإيداع. حاول مرة أخرى.';
      await _sendSystemMessage(groupId, warning);
      await refreshMessages(groupId);
      return warning;
    }
  }

  /// Answers "رصيد المحفظة" — posts the selected wallet's current balance.
  Future<void> showWalletBalance(String groupId, WalletModel wallet,
      {String? requesterId}) async {
    var w = wallet;
    try {
      final wallets = await _db.getWalletsSync(groupId);
      w = wallets.firstWhere((x) => x.id == wallet.id, orElse: () => wallet);
    } catch (_) {}
    final updated = w.updatedAt == null
        ? ''
        : '\nآخر تحديث: ${DateFormat('yyyy/MM/dd HH:mm').format(w.updatedAt!)}';
    final by = (w.updatedByName ?? '').trim().isEmpty
        ? ''
        : ' — بواسطة ${w.updatedByLabel}';
    await _sendSystemMessage(
      groupId,
      '👛 رصيد ${w.name}: ${w.balance.toStringAsFixed(0)} ج$updated$by',
      targetUserId: requesterId,
    );
    await refreshMessages(groupId);
  }

  /// Answers "حركة المحفظة / تقرير المحفظة" — posts the recent ledger lines.
  Future<void> showWalletMovement(String groupId, WalletModel wallet,
      {String? requesterId}) async {
    final entries = await _db.getWalletEntriesSync(groupId, wallet.id);
    if (entries.isEmpty) {
      await _sendSystemMessage(
          groupId, '📒 لا توجد حركة على ${wallet.name} بعد.',
          targetUserId: requesterId);
      await refreshMessages(groupId);
      return;
    }
    final recent = entries.reversed.take(12).toList(); // newest first
    final df = DateFormat('MM/dd HH:mm');
    final current = entries.last.balanceAfter; // last = newest = current
    final lines = <String>[
      '📒 حركة ${wallet.name} — آخر ${recent.length} عملية:',
    ];
    for (final e in recent) {
      final sign = e.isDebit ? '+' : '-';
      lines.add(
          '${df.format(e.at)} | ${_entryStatementLabel(e)} | $sign${e.amount.toStringAsFixed(0)} | رصيد ${e.balanceAfter.toStringAsFixed(0)}');
    }
    if (entries.length > recent.length) {
      lines.add('… الباقي في شاشة المحافظ بالإعدادات.');
    }
    lines.add('الرصيد الحالي: ${current.toStringAsFixed(0)} ج');
    await _sendSystemMessage(groupId, lines.join('\n'),
        targetUserId: requesterId);
    await refreshMessages(groupId);
  }

  String _entryStatementLabel(WalletEntryModel e) {
    final note = (e.note ?? '').trim();
    if (note.isNotEmpty) return note;
    switch (e.source) {
      case 'opening':
        return 'رصيد افتتاحي';
      case 'injection':
        return 'إيداع نقدي';
      case 'withdrawal':
        return 'سحب نقدي';
      case 'expense':
        return 'مصروف';
      case 'adjustment':
        return 'تعديل رصيد';
      case 'reversal':
        return 'إرجاع';
      case 'transfer':
        return 'تحويل';
      default:
        return e.source;
    }
  }

  /// Corrects an expense's category and teaches the parser from it (offline).
  Future<void> recategorizeExpense(
      String groupId, ChatMessage message, String category) async {
    final txId = message.transactionId;
    if (txId == null || txId.isEmpty) return;
    await _db.recategorizeExpense(groupId, txId, category);
    _messages = await _db.getMessagesSync(groupId);
    notifyListeners();
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

    // deleteTransaction posts the wallet reversal itself (ledger integrity).
    final deleted = await _db.deleteTransaction(
      groupId,
      message.transactionId!,
      byName: user.name,
      byPhone: user.phone,
    );
    if (deleted == null)
      return 'لم أجد المصروف في السجلات. ربما تم حذفه من قبل.';

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

  Future<void> _sendSystemMessage(String groupId, String content,
      {String? targetUserId}) async {
    final systemMsg = ChatMessage(
      id: _uuid.v4(),
      groupId: groupId,
      senderId: 'system',
      senderName: 'مساعد العائلة',
      type: MessageType.system,
      content: content,
      timestamp: DateTime.now(),
      targetUserId: targetUserId,
    );
    await _db.sendMessage(systemMsg);
  }

  void _applyStoredMatches(
    Map<String, dynamic> aiResult,
    String text,
    List<String> categories,
    List<dynamic> budgets,
    List<UserModel> members, {
    Map<String, String> learned = const {},
  }) {
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

    // User-taught keywords win — this is the offline "learning" from corrections.
    if (learned.isNotEmpty) {
      final textKey = CategoryUtils.key(text);
      for (final entry in learned.entries) {
        if (entry.key.length >= 3 && textKey.contains(entry.key)) {
          aiResult['category'] = entry.value;
          break;
        }
      }
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
