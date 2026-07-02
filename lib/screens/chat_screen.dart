import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:app_links/app_links.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/budget_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/avatar_provider.dart';
import '../models/chat_message_model.dart';
import '../models/resolved_expense.dart';
import '../models/wallet_model.dart';
import '../models/user_model.dart';
import '../services/voice_service.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import '../services/local_notice_service.dart';
import 'member_detail_screen.dart';
import '../utils/category_utils.dart';
import '../utils/money_format.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/expense_confirm_dialog.dart';
import '../widgets/message_input.dart';
import 'members_screen.dart';
import 'group_settings_screen.dart';
import 'analytics_screen.dart';
import 'notifications_screen.dart';
import 'teams_screen.dart';
import 'wallets_overview_screen.dart';
import 'expenses_overview_screen.dart';

class ChatScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const ChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  final _voiceService = VoiceService();
  final _db = DatabaseService();
  final _localNotice = const LocalNoticeService();
  List<UserModel> _members = [];
  final _appLinks = AppLinks();
  bool _isRecording = false;
  bool _isSending = false;
  bool _isSyncingFamilyData = false;
  bool _isPreparingVoice = false;
  bool _isConfirmingVoice = false;
  bool _handlingInviteLink = false;
  Timer? _familyRefreshTimer;
  StreamSubscription<Uri>? _deepLinkSub;
  NotificationProvider? _notificationProvider;
  int _lastUnreadCount = 0;
  String? _lastShownNotificationId;
  bool _notificationListenerReady = false;
  String? _lastSubmittedText;
  DateTime? _lastSubmittedAt;
  String? _lastParsedPreview;
  // In-app update notice: set when a newer build exists than the one running.
  String? _updateVersion;
  bool _updateDismissed = false;
  // WhatsApp-style reply: the message the next send will quote (null = none).
  ChatMessage? _replyTo;

  @override
  void initState() {
    super.initState();
    _listenForInviteLinks();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      context.read<ChatProvider>().subscribeMessages(widget.groupId);
      final auth = context.read<AuthProvider>();
      unawaited(context.read<AvatarProvider>().load(widget.groupId));
      _db.checkForUpdate().then((v) {
        if (mounted && v != null) setState(() => _updateVersion = v);
      });
      final userId = auth.user?.id;
      if (userId != null) {
        final notifications = context.read<NotificationProvider>();
        notifications.subscribe(widget.groupId, userId,
            isAdmin: auth.user?.isAdmin == true);
        _notificationProvider = notifications;
        notifications.addListener(_handleLiveNotification);
        await _localNotice.requestPermission();
      }
      if (auth.user?.isAdmin == true) {
        try {
          final members = await _db.getFamilyMembersSync(widget.groupId);
          if (mounted) setState(() => _members = members);
        } catch (_) {}
      }
      await _refreshFamilyData();
      _familyRefreshTimer?.cancel();
      _familyRefreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        _refreshFamilyData(silent: true);
      });
    });
  }

  void _handleLiveNotification() {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    final latest = _notificationProvider?.latestUnreadFromOther(auth.user?.id);
    if (!_notificationListenerReady) {
      _lastShownNotificationId = latest?.id;
      _notificationListenerReady = true;
      return;
    }
    if (latest == null || latest.id == _lastShownNotificationId) return;
    _lastShownNotificationId = latest.id;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('🔔 ${latest.title}: ${latest.body}')),
    );
    _localNotice.show(latest.title, latest.body);
    setState(() => _isSyncingFamilyData = true);
    unawaited(context
        .read<BudgetProvider>()
        .refreshData(widget.groupId)
        .whenComplete(() {
      if (mounted) setState(() => _isSyncingFamilyData = false);
    }));
  }

  bool _hasInvite(Uri uri) {
    final params = uri.queryParameters;
    return (params['invite'] ?? params['code'] ?? '').trim().isNotEmpty ||
        (params['groupId'] ?? params['familyId'] ?? '').trim().isNotEmpty;
  }

  Future<void> _listenForInviteLinks() async {
    try {
      _deepLinkSub = _appLinks.uriLinkStream.listen((uri) async {
        if (!_hasInvite(uri) || !mounted || _handlingInviteLink) return;
        _handlingInviteLink = true;
        try {
          final auth = context.read<AuthProvider>();
          await auth.signOut();
          if (!mounted) return;
          Navigator.pushNamedAndRemoveUntil(
            context,
            '/auth',
            (_) => false,
            arguments: {'inviteUri': uri.toString()},
          );
        } finally {
          _handlingInviteLink = false;
        }
      });
    } catch (_) {
      // Splash/Auth still handle cold-start invite links.
    }
  }

  Future<void> _refreshFamilyData({bool silent = false}) async {
    if (!mounted) return;
    try {
      final auth = context.read<AuthProvider>();
      await context.read<BudgetProvider>().refreshData(widget.groupId);
      final notifications = context.read<NotificationProvider>();
      final newUnread = notifications.unreadCount;
      final latest = notifications.latestUnreadFromOther(auth.user?.id);
      if (silent &&
          mounted &&
          newUnread > _lastUnreadCount &&
          latest != null &&
          latest.id != _lastShownNotificationId) {
        _lastShownNotificationId = latest.id;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('🔔 ${latest.title}: ${latest.body}')),
        );
        _localNotice.show(latest.title, latest.body);
      }
      _lastUnreadCount = newUnread;
      await auth.refreshCurrentUser();
    } catch (_) {
      // Keep the screen usable during temporary network drops.
    }
  }

  @override
  void dispose() {
    _familyRefreshTimer?.cancel();
    _deepLinkSub?.cancel();
    _notificationProvider?.removeListener(_handleLiveNotification);
    _scrollController.dispose();
    _textController.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage([String? forcedText]) async {
    if (_isSending) return;
    setState(() => _isSending = true);
    final text = (forcedText ?? _textController.text).trim();
    if (text.isEmpty) {
      if (mounted) setState(() => _isSending = false);
      return;
    }

    final now = DateTime.now();
    if (_lastSubmittedText == text &&
        _lastSubmittedAt != null &&
        now.difference(_lastSubmittedAt!) < const Duration(seconds: 6)) {
      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إرسال نفس المصروف بالفعل.')),
        );
      }
      return;
    }
    _lastSubmittedText = text;
    _lastSubmittedAt = now;

    if (_isRecording) {
      await _voiceService.stopListening();
      if (mounted) setState(() => _isRecording = false);
    }

    // Wallet questions (read-only): balance / movement — before expense parsing.
    final walletQuery = AIService.parseWalletQuery(text);
    if (walletQuery != null) {
      final isBalance = walletQuery['type'] == 'balance';
      final qUser = context.read<AuthProvider>().user;
      WalletModel? wallet;
      if (qUser != null && !qUser.isAdmin) {
        // A member can only ask about their own wallet.
        for (final w in context.read<BudgetProvider>().wallets) {
          if (w.isMemberWallet && w.ownerId == qUser.id) {
            wallet = w;
            break;
          }
        }
      } else {
        wallet = await _pickAnyWallet(
          title: isBalance ? 'رصيد أي محفظة؟' : 'حركة أي محفظة؟',
          hint: walletQuery['walletHint'] as String?,
        );
      }
      if (wallet == null || wallet == _walletSelectionCancelled) {
        _putTextInInput(text);
        _lastSubmittedText = null;
        _lastSubmittedAt = null;
        if (mounted) setState(() => _isSending = false);
        return;
      }
      _textController.clear();
      setState(() => _lastParsedPreview = null);
      try {
        final chat = context.read<ChatProvider>();
        if (isBalance) {
          await chat.showWalletBalance(widget.groupId, wallet,
              requesterId: qUser?.id);
        } else {
          await chat.showWalletMovement(widget.groupId, wallet,
              requesterId: qUser?.id);
        }
        await chat.refreshMessages(widget.groupId);
      } finally {
        if (mounted) setState(() => _isSending = false);
      }
      _scrollToBottom();
      return;
    }

    // Intent-first money commands (add / withdraw / transfer / set limit) —
    // the verb decides, not the number. Checked before expense parsing.
    final moneyCmd = AIService.parseMoneyCommand(text);
    if (moneyCmd != null) {
      _textController.clear();
      setState(() => _lastParsedPreview = null);
      try {
        await _handleMoneyCommand(moneyCmd);
      } catch (e) {
        if (mounted) _snack('تعذّر تنفيذ الأمر: $e');
      } finally {
        // Reset send state FIRST (synchronously) so a failing/slow refresh can
        // never leave the input stuck on "pending" and blocking all sends.
        _lastSubmittedText = null;
        _lastSubmittedAt = null;
        if (mounted) setState(() => _isSending = false);
        try {
          await context.read<ChatProvider>().refreshMessages(widget.groupId);
        } catch (_) {}
        _scrollToBottom();
      }
      return;
    }

    // "Cash into wallet" (external cash in) — admin-only, into an admin wallet.
    final injection = AIService.parseWalletInjection(text);
    if (injection != null) {
      final actor = context.read<AuthProvider>().user;
      if (actor == null || !actor.isAdmin) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('إضافة الأموال من صلاحية القائد فقط.')));
        }
        _putTextInInput(text);
        _lastSubmittedText = null;
        _lastSubmittedAt = null;
        if (mounted) setState(() => _isSending = false);
        return;
      }
      final wallet = await _pickAnyWallet(
        title: 'تضيف الفلوس في أي محفظة؟',
        hint: injection['walletHint'] as String?,
        adminOnly: true,
      );
      if (wallet == null || wallet == _walletSelectionCancelled) {
        _putTextInInput(text);
        _lastSubmittedText = null;
        _lastSubmittedAt = null;
        if (mounted) setState(() => _isSending = false);
        return;
      }
      final auth = context.read<AuthProvider>();
      if (auth.user == null) {
        if (mounted) setState(() => _isSending = false);
        return;
      }
      _textController.clear();
      setState(() => _lastParsedPreview = null);
      try {
        final chat = context.read<ChatProvider>();
        final warning = await chat.injectToWallet(
          widget.groupId,
          auth.user!,
          injection['amount'] as double,
          wallet,
          note: text,
        );
        await chat.refreshMessages(widget.groupId);
        await context.read<BudgetProvider>().refreshData(widget.groupId);
        if (mounted && warning != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(warning)));
        }
      } finally {
        if (mounted) setState(() => _isSending = false);
      }
      _scrollToBottom();
      return;
    }

    final auth = context.read<AuthProvider>();
    if (auth.user == null) {
      if (mounted) setState(() => _isSending = false);
      return;
    }

    final chat = context.read<ChatProvider>();
    List<ResolvedExpense> resolved;
    try {
      resolved = await chat.resolveExpenseMessages(
        widget.groupId,
        text,
        auth.user!,
        categories: context.read<BudgetProvider>().categories,
      );
    } catch (_) {
      resolved = const [];
    }

    if (resolved.isNotEmpty) {
      // Mandatory confirm-before-save: shows the FINAL resolved category for
      // every item (even a single one) with a change-type control, so nothing
      // saves silently.
      final confirmedItems = await confirmResolvedExpenses(
          context, resolved, context.read<BudgetProvider>().categories);
      if (confirmedItems == null) {
        _putTextInInput(text);
        _lastSubmittedText = null;
        _lastSubmittedAt = null;
        if (mounted) setState(() => _isSending = false);
        return;
      }
      resolved = confirmedItems;

      final totalExpense = resolved
          .where((r) => r.isExpense)
          .fold<double>(0, (sum, r) => sum + r.amount);
      // Teams are reporting rollups now — no per-expense team selection.
      final selectedWallet =
          totalExpense > 0 ? await _pickWalletForExpense(totalExpense) : null;
      if (totalExpense > 0 && selectedWallet == _walletSelectionCancelled) {
        _putTextInInput(text);
        _lastSubmittedText = null;
        _lastSubmittedAt = null;
        if (mounted) setState(() => _isSending = false);
        return;
      }
      // Hard limit: you can't spend more than the wallet holds.
      if (totalExpense > 0 &&
          selectedWallet != null &&
          totalExpense > selectedWallet.balance + 0.005) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'الرصيد غير كافٍ في ${selectedWallet.name}. المتاح ${formatMoney(selectedWallet.balance)} ج.'),
          ));
        }
        _putTextInInput(text);
        _lastSubmittedText = null;
        _lastSubmittedAt = null;
        if (mounted) setState(() => _isSending = false);
        return;
      }

      _textController.clear();
      setState(() => _lastParsedPreview = null);
      final replyTo = _replyTo;
      if (mounted) setState(() => _replyTo = null);
      try {
        final warning = await chat.commitResolvedExpenses(
          widget.groupId,
          auth.user!,
          text,
          resolved,
          wallet: selectedWallet,
          replyTo: replyTo,
        );
        await chat.refreshMessages(widget.groupId);
        await context.read<BudgetProvider>().refreshData(widget.groupId);
        await context.read<NotificationProvider>().load(widget.groupId);
        await auth.refreshCurrentUser();
        if (mounted && warning != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(warning)));
        }
      } finally {
        if (mounted) setState(() => _isSending = false);
      }
      _scrollToBottom();
      return;
    }

    // Nothing resolved as an expense/income: plain text, a report request, or
    // (for the admin) a message that may need routing to a specific member.
    String? directTargetUserId;
    if (auth.user!.isAdmin &&
        AIService.parseReportRequest(text) == null &&
        !AIService.isNextReportCommand(text)) {
      final isReplyToMember = _replyTo != null &&
          _members.any((m) => m.id == _replyTo!.senderId && !m.isAdmin);
      if (isReplyToMember) {
        // A reply already knows its recipient — the person you replied to.
        directTargetUserId = _replyTo!.senderId;
      } else {
        final routed = await _routeAdminMessage(text);
        if (routed == null) {
          _putTextInInput(text);
          _lastSubmittedText = null;
          _lastSubmittedAt = null;
          if (mounted) setState(() => _isSending = false);
          return;
        }
        directTargetUserId = routed.isEmpty ? null : routed;
      }
    }

    _textController.clear();
    setState(() {
      _lastParsedPreview = null;
    });

    final replyTo = _replyTo;
    if (mounted) setState(() => _replyTo = null);
    try {
      final warning = await chat.sendTextMessage(
        widget.groupId,
        auth.user!,
        text,
        team: null,
        targetUserId: directTargetUserId,
        replyTo: replyTo,
      );
      await chat.refreshMessages(widget.groupId);
      await context.read<BudgetProvider>().refreshData(widget.groupId);
      await context.read<NotificationProvider>().load(widget.groupId);
      await auth.refreshCurrentUser();

      if (mounted && warning != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(warning)));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
    _scrollToBottom();
  }

  void _putTextInInput(String text) {
    _textController.text = text;
    _textController.selection =
        TextSelection.fromPosition(TextPosition(offset: text.length));
    _updateParsedPreview(text);
  }

  static final WalletModel _walletSelectionCancelled = WalletModel(
    id: '__cancelled__',
    name: '__cancelled__',
    balance: 0,
  );

  /// Routes an admin's plain-text message. Returns: null = cancelled,
  /// '' = send to everyone, or a member id = a direct message to that member.
  Future<String?> _routeAdminMessage(String text) async {
    final members = _members.where((m) => !m.isAdmin).toList();
    if (members.isEmpty) return '';
    final norm = CategoryUtils.key(text);
    final matches = members.where((m) {
      final nk = CategoryUtils.key(m.name);
      return nk.length >= 2 && norm.contains(nk);
    }).toList();
    if (matches.length == 1) return matches.first.id;
    if (!mounted) return '';
    return showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('إرسال الرسالة إلى؟'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('كل العائلة'),
          ),
          ...members.map((m) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, m.id),
                child: Text(m.name),
              )),
        ],
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirmCmd(String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد العملية'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تنفيذ')),
        ],
      ),
    );
    return ok == true;
  }

  /// Executes an intent-first money command (add / withdraw / transfer / set
  /// limit). Admin-only; every move confirms first. Names in the message are
  /// matched to a wallet or a person (member/worker) automatically.
  Future<void> _handleMoneyCommand(Map<String, dynamic> cmd) async {
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null) return;
    if (!user.isAdmin) {
      _snack('هذه العملية من صلاحية القائد فقط.');
      return;
    }
    final intent = cmd['intent'] as String;
    final amount = cmd['amount'] as double?;
    final text = (cmd['text'] as String?) ?? '';
    final fromHint = cmd['fromHint'] as String?;
    final toHint = cmd['toHint'] as String?;

    final budget = context.read<BudgetProvider>();
    await budget.refreshData(widget.groupId);
    final wallets = budget.wallets;
    final adminWallets = wallets.where((w) => w.isAdminWallet).toList();
    final people = (await _db.getMembersSync(widget.groupId))
        .where((m) => !m.isAdmin)
        .toList();

    UserModel? person(String? hint) {
      final hk = CategoryUtils.key((hint == null || hint.isEmpty) ? text : hint);
      for (final p in people) {
        final nk = CategoryUtils.key(p.name);
        if (nk.length >= 2 && hk.contains(nk)) return p;
      }
      return null;
    }

    WalletModel? walletByName(String? hint, {bool adminOnly = false}) {
      final pool = adminOnly ? adminWallets : wallets;
      final hk = CategoryUtils.key((hint == null || hint.isEmpty) ? text : hint);
      for (final w in pool) {
        final nk = CategoryUtils.key(w.name);
        if (nk.length >= 2 && hk.contains(nk)) return w;
      }
      return null;
    }

    WalletModel? walletOf(UserModel p) {
      for (final w in wallets) {
        if (w.isMemberWallet && w.ownerId == p.id) return w;
      }
      return null;
    }

    Future<void> done(String? errOrNull, String successMsg,
        {List<String> targets = const []}) async {
      await budget.refreshData(widget.groupId);
      if (errOrNull == null && successMsg.isNotEmpty) {
        // The affected member (if any) — so they see it in their own chat.
        String? chatTarget;
        for (final id in targets) {
          if (id != user.id) {
            chatTarget = id;
            break;
          }
        }
        // Post the action to the chat feed so there's a visible record.
        await _db.sendMessage(ChatMessage(
          id: 'mc_${DateTime.now().microsecondsSinceEpoch}',
          groupId: widget.groupId,
          senderId: user.id,
          senderName: user.name,
          type: MessageType.system,
          content: '💸 $successMsg',
          timestamp: DateTime.now(),
          targetUserId: chatTarget,
        ));
        // Notify both parties (admin + the affected member).
        await _db.notifyMultiple(
          widget.groupId,
          title: 'حركة مالية',
          body: successMsg,
          actorId: user.id,
          actorName: user.name,
          targetUserIds: targets,
        );
      }
      if (!mounted) return;
      await context.read<NotificationProvider>().load(widget.groupId);
      _snack(errOrNull ?? successMsg);
    }

    if (intent == 'raiseLimit' || intent == 'lowerLimit') {
      final p = person(toHint);
      if (p == null) return _snack('لمن تضبط الحد؟ اكتب اسمه بوضوح.');
      if (amount == null) return _snack('اكتب قيمة الحد.');
      if (!await _confirmCmd(
          'ضبط حد ${p.name} الشهري على ${formatMoney(amount)} ج؟')) {
        return;
      }
      await _db.updateMemberLimit(widget.groupId, p.id, amount);
      await done(null, 'تم ضبط حد ${p.name} على ${formatMoney(amount)} ج',
          targets: [user.id, p.id]);
      return;
    }

    if (amount == null) return _snack('اكتب المبلغ.');

    if (intent == 'transfer') {
      final toPerson = person(toHint);
      final from = walletByName(fromHint) ??
          (adminWallets.isNotEmpty ? adminWallets.first : null);
      if (toPerson != null) {
        final pw = walletOf(toPerson);
        if (from == null || pw == null) return _snack('تعذّر تحديد المحافظ.');
        if (!await _confirmCmd(
            'تحويل ${formatMoney(amount)} ج من ${from.name} إلى ${toPerson.name}؟')) {
          return;
        }
        final err = await _db.transferBetweenWallets(widget.groupId,
            fromWalletId: from.id,
            toWalletId: pw.id,
            amount: amount,
            byName: user.name,
            byPhone: user.phone);
        await done(
            err, 'تم تحويل ${formatMoney(amount)} ج إلى ${toPerson.name}',
            targets: [user.id, toPerson.id]);
        return;
      }
      // Wallet → wallet. Whatever the message didn't specify, ask for it.
      var fromW = walletByName(fromHint);
      fromW ??= await _pickAnyWallet(title: 'حوّل من أي محفظة؟');
      if (fromW == null) return _snack('لا توجد محافظ.');
      if (fromW == _walletSelectionCancelled) return;
      var toW = walletByName(toHint);
      toW ??=
          await _pickAnyWallet(title: 'إلى أي محفظة؟', excludeId: fromW.id);
      if (toW == null) return _snack('لا توجد محفظة أخرى للتحويل إليها.');
      if (toW == _walletSelectionCancelled) return;
      if (fromW.id == toW.id) return _snack('اختر محفظتين مختلفتين.');
      if (!await _confirmCmd(
          'تحويل ${formatMoney(amount)} ج من ${fromW.name} إلى ${toW.name}؟')) {
        return;
      }
      final err = await budget.transfer(widget.groupId,
          fromWalletId: fromW.id,
          toWalletId: toW.id,
          amount: amount,
          byName: user.name,
          byPhone: user.phone);
      // Notify any member whose wallet was touched (plus the admin actor).
      final involved = <String>[user.id];
      if (fromW.isMemberWallet && (fromW.ownerId ?? '').isNotEmpty) {
        involved.add(fromW.ownerId!);
      }
      if (toW.isMemberWallet && (toW.ownerId ?? '').isNotEmpty) {
        involved.add(toW.ownerId!);
      }
      await done(
          err,
          'تم تحويل ${formatMoney(amount)} ج من ${fromW.name} إلى ${toW.name}',
          targets: involved);
      return;
    }

    if (intent == 'withdraw') {
      final p = person(fromHint);
      if (p != null) {
        final pw = walletOf(p);
        final to = adminWallets.isNotEmpty ? adminWallets.first : null;
        if (pw == null || to == null) return _snack('تعذّر تحديد المحافظ.');
        if (!await _confirmCmd(
            'سحب ${formatMoney(amount)} ج من ${p.name} إلى ${to.name}؟')) {
          return;
        }
        final err = await _db.transferBetweenWallets(widget.groupId,
            fromWalletId: pw.id,
            toWalletId: to.id,
            amount: amount,
            byName: user.name,
            byPhone: user.phone);
        await done(err, 'تم سحب ${formatMoney(amount)} ج من ${p.name}',
            targets: [user.id, p.id]);
        return;
      }
      var w = walletByName(fromHint);
      w ??= await _pickAnyWallet(title: 'تسحب نقدًا من أي محفظة؟');
      if (w == null) return _snack('لا توجد محافظ.');
      if (w == _walletSelectionCancelled) return;
      if (!await _confirmCmd(
          'سحب نقدي ${formatMoney(amount)} ج من ${w.name}؟')) {
        return;
      }
      final err = await budget.walletCashMovement(widget.groupId, w.id, amount,
          deposit: false, byName: user.name, byPhone: user.phone);
      await done(err, 'تم سحب ${formatMoney(amount)} ج من ${w.name}');
      return;
    }

    // intent == 'add'
    final p = person(toHint);
    if (p != null) {
      final pw = walletOf(p);
      final from = adminWallets.isNotEmpty ? adminWallets.first : null;
      if (from == null) return _snack('أضف محفظة نقدية لك أولًا من الإعدادات.');
      if (pw == null) return _snack('محفظة ${p.name} غير جاهزة بعد.');
      if (!await _confirmCmd(
          'إضافة ${formatMoney(amount)} ج إلى ${p.name} من ${from.name}؟')) {
        return;
      }
      final err = await _db.transferBetweenWallets(widget.groupId,
          fromWalletId: from.id,
          toWalletId: pw.id,
          amount: amount,
          byName: user.name,
          byPhone: user.phone);
      await done(err, 'تم إضافة ${formatMoney(amount)} ج إلى ${p.name}',
          targets: [user.id, p.id]);
      return;
    }
    var w = walletByName(toHint, adminOnly: true);
    w ??= await _pickAnyWallet(title: 'تضيف الفلوس في أي محفظة؟', adminOnly: true);
    if (w == null || w == _walletSelectionCancelled) return;
    if (!await _confirmCmd('إضافة ${formatMoney(amount)} ج في ${w.name}؟')) {
      return;
    }
    final err = await context
        .read<ChatProvider>()
        .injectToWallet(widget.groupId, user, amount, w, note: text);
    await done(err, '');
  }

  Future<WalletModel?> _pickWalletForExpense(double amount) async {
    final budget = context.read<BudgetProvider>();
    final user = context.read<AuthProvider>().user;
    if (user == null) return null;

    // A member always spends from their own single wallet — no choice.
    if (!user.isAdmin) {
      for (final w in budget.wallets) {
        if (w.isMemberWallet && w.ownerId == user.id) return w;
      }
      return null; // not provisioned yet
    }

    // The admin chooses which of his cash wallets to spend from.
    var wallets = budget.wallets.where((w) => w.isAdminWallet).toList();
    if (wallets.isEmpty) return null;
    if (wallets.length == 1) return wallets.first;
    wallets = wallets
      ..sort((a, b) {
        if (a.isDefault && !b.isDefault) return -1;
        if (!a.isDefault && b.isDefault) return 1;
        return b.balance.compareTo(a.balance);
      });
    final selected = await showDialog<WalletModel>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تخصم من أي محفظة؟'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('قيمة المصروف: ${formatMoney(amount)} ج'),
            const SizedBox(height: 8),
            ...wallets.map(
              (wallet) => RadioListTile<WalletModel>(
                value: wallet,
                groupValue: null,
                onChanged: (value) => Navigator.pop(ctx, value),
                title: Text(wallet.name),
                subtitle:
                    Text('الرصيد: ${formatMoney(wallet.balance)} ج'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _walletSelectionCancelled),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
    return selected ?? _walletSelectionCancelled;
  }

  /// Pick any wallet (all eligible). Returns the wallet,
  /// [_walletSelectionCancelled] on cancel, or null if there are no wallets.
  /// If [hint] matches a wallet name, it is chosen without prompting.
  Future<WalletModel?> _pickAnyWallet(
      {required String title,
      String? hint,
      bool adminOnly = false,
      String? excludeId}) async {
    final budget = context.read<BudgetProvider>();
    final wallets = (adminOnly
            ? budget.wallets.where((w) => w.isAdminWallet)
            : budget.wallets)
        .where((w) => excludeId == null || w.id != excludeId)
        .toList();
    if (wallets.isEmpty) return null;

    if (hint != null && hint.trim().isNotEmpty) {
      final hintKey = CategoryUtils.key(hint);
      for (final w in wallets) {
        final nameKey = CategoryUtils.key(w.name);
        if (nameKey.isNotEmpty &&
            (nameKey.contains(hintKey) || hintKey.contains(nameKey))) {
          return w;
        }
      }
    }

    if (wallets.length == 1) return wallets.first;
    wallets.sort((a, b) {
      if (a.isDefault && !b.isDefault) return -1;
      if (!a.isDefault && b.isDefault) return 1;
      return a.name.compareTo(b.name);
    });
    if (!mounted) return _walletSelectionCancelled;
    final selected = await showDialog<WalletModel>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...wallets.map(
              (wallet) => RadioListTile<WalletModel>(
                value: wallet,
                groupValue: null,
                onChanged: (value) => Navigator.pop(ctx, value),
                title: Text(wallet.name),
                subtitle:
                    Text('الرصيد: ${formatMoney(wallet.balance)} ج'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _walletSelectionCancelled),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
    return selected ?? _walletSelectionCancelled;
  }

  Future<void> _deleteExpenseEntry(message) async {
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الإدخال'),
        content: const Text(
            'هل تريد حذف هذا المصروف من السجلات؟ سيتم إرجاع تأثيره للميزانية والتقارير فورًا.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('حذف وإرجاع المبلغ'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final warning = await context
        .read<ChatProvider>()
        .deleteExpenseEntry(widget.groupId, user, message);
    await context.read<ChatProvider>().refreshMessages(widget.groupId);
    await context.read<BudgetProvider>().refreshData(widget.groupId);
    await context.read<NotificationProvider>().load(widget.groupId);
    await auth.refreshCurrentUser();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(warning ?? 'تم حذف الإدخال وتحديث الميزانية')),
    );
  }

  /// Long-press menu for an expense: change its category (teaches the parser)
  /// or delete it.
  Widget _replyBanner() {
    final r = _replyTo!;
    final preview = r.type == MessageType.expense && r.amount != null
        ? '${r.category ?? 'مصروف'}: ${formatMoney(r.amount!)} ج'
        : r.content;
    return Container(
      color: AppTheme.systemMessage,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Container(width: 3, height: 36, color: AppTheme.primaryGreen),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('رد على ${r.senderName}',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryGreen)),
                Text(preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: 'إلغاء الرد',
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  /// Long-press menu for any message: reply (WhatsApp-style), plus the expense
  /// edit/delete actions when the message is an editable expense.
  Future<void> _showMessageActions(ChatMessage message, UserModel? user) async {
    if (message.isDeleted || message.type == MessageType.system) return;
    final canEditExpense = message.type == MessageType.expense &&
        (message.senderId == user?.id || user?.isAdmin == true);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('رد'),
              onTap: () => Navigator.pop(ctx, 'reply'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('نسخ النص'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            if (canEditExpense)
              ListTile(
                leading: const Icon(Icons.category_rounded),
                title: const Text('تغيير النوع'),
                onTap: () => Navigator.pop(ctx, 'recat'),
              ),
            if (canEditExpense)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded,
                    color: Colors.red),
                title: const Text('حذف الإدخال',
                    style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (action == 'reply') {
      if (mounted) setState(() => _replyTo = message);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.content));
      _snack('تم نسخ النص');
    } else if (action == 'delete') {
      await _deleteExpenseEntry(message);
    } else if (action == 'recat') {
      await _recategorize(message);
    }
  }

  Future<void> _recategorize(ChatMessage message) async {
    final categoryModels =
        context.read<BudgetProvider>().categories.where((c) => !c.isIncome).toList();
    if (categoryModels.isEmpty) return;
    final chosen = await pickCategory(context, categoryModels);
    if (chosen == null || !mounted) return;
    final user = context.read<AuthProvider>().user;
    if (user == null) return;
    await context
        .read<ChatProvider>()
        .recategorizeExpense(widget.groupId, user, message, chosen.name);
    await context.read<BudgetProvider>().refreshData(widget.groupId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'تم تغيير النوع إلى "${chosen.name}" — وسيتعلّمه المساعد للمرة القادمة')),
    );
  }

  Future<void> _openAccountDialog() async {
    final auth = context.read<AuthProvider>();
    final avatars = context.read<AvatarProvider>();
    final user = auth.user;
    if (user == null) return;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _UserAvatar(
                name: user.name,
                photoBytes: avatars.bytesFor(user.id),
                radius: 42),
            const SizedBox(height: 12),
            Text(user.name,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            if (user.phone != null && user.phone!.isNotEmpty) Text(user.phone!),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final picked = await ImagePicker().pickImage(
                  source: ImageSource.gallery,
                  imageQuality: 78,
                  maxWidth: 800,
                );
                if (picked == null) return;
                final bytes = await picked.readAsBytes();
                await avatars.setAvatar(widget.groupId, user.id, bytes);
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.photo_camera_back_rounded),
              label: const Text('رفع صورة للحساب'),
            ),
            const SizedBox(height: 8),
            const Text(
              'الصورة تظهر لكل أفراد العائلة على الرسائل وكروت الأعضاء.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final nameC = TextEditingController(text: user.name);
                  final newName = await showDialog<String>(
                    context: ctx,
                    builder: (dctx) => AlertDialog(
                      title: const Text('تعديل اسمي'),
                      content: TextField(
                        controller: nameC,
                        autofocus: true,
                        decoration: const InputDecoration(
                            labelText: 'الاسم', border: OutlineInputBorder()),
                      ),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(dctx),
                            child: const Text('إلغاء')),
                        FilledButton(
                            onPressed: () =>
                                Navigator.pop(dctx, nameC.text.trim()),
                            child: const Text('حفظ')),
                      ],
                    ),
                  );
                  nameC.dispose();
                  if (newName == null || newName.isEmpty) return;
                  await auth.updateMyName(newName);
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.edit_rounded),
                label: const Text('تعديل اسمي'),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await auth.signOut();
                  if (mounted) {
                    Navigator.pushNamedAndRemoveUntil(
                        context, '/auth', (_) => false);
                  }
                },
                icon: const Icon(Icons.logout_rounded),
                label: const Text('تسجيل الخروج'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Web: reload the current tab (the no-cache hosting serves the new build).
  /// Native: open the APK download page so the user installs the update.
  Future<void> _doUpdate() async {
    final uri = Uri.parse(
        kIsWeb ? AppConstants.appWebLink : AppConstants.androidDownloadLink);
    try {
      if (kIsWeb) {
        await launchUrl(uri, webOnlyWindowName: '_self');
      } else {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذّر فتح رابط التحديث.')),
        );
      }
    }
  }

  Future<void> _onMenuSelected(String value) async {
    switch (value) {
      case 'invite':
        await _shareAppInvite();
        break;
      case 'teams':
        await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TeamsScreen(groupId: widget.groupId)),
        );
        break;
      case 'settings':
        await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => GroupSettingsScreen(groupId: widget.groupId)),
        );
        break;
      case 'switch':
        final authProvider = context.read<AuthProvider>();
        final navigator = Navigator.of(context);
        await authProvider.switchAccount();
        if (!mounted) return;
        navigator.pushNamedAndRemoveUntil('/auth', (_) => false);
        break;
      case 'logout':
        final authProvider = context.read<AuthProvider>();
        final navigator = Navigator.of(context);
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('تسجيل الخروج'),
            content: const Text('هل تريد الخروج من حسابك على هذا الجهاز؟'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('إلغاء')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('خروج')),
            ],
          ),
        );
        if (ok != true) return;
        await authProvider.signOut();
        if (!mounted) return;
        navigator.pushNamedAndRemoveUntil('/auth', (_) => false);
        break;
    }
  }

  Future<void> _shareAppInvite() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('مشاركة Home Budgets'),
                subtitle: Text('اختار نوع الرسالة قبل فتح واتساب.'),
              ),
              ListTile(
                leading: const Icon(Icons.group_add_rounded),
                title: const Text('دعوة فرد للانضمام لعائلتنا'),
                subtitle: const Text('يرسل رابط فيه كود العائلة الحالية.'),
                onTap: () => Navigator.pop(ctx, 'family'),
              ),
              ListTile(
                leading: const Icon(Icons.public_rounded),
                title: const Text('رابط تجربة وإنشاء عائلة جديدة'),
                subtitle:
                    const Text('يرسل رابط بدون كود دعوة، فينشئ عائلته هو.'),
                onTap: () => Navigator.pop(ctx, 'trial'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == 'family') {
      await _shareFamilyInvite();
    } else if (choice == 'trial') {
      await _shareNewFamilyTrial();
    }
  }

  Future<void> _shareFamilyInvite() async {
    final groupId = context.read<AuthProvider>().group?.id ?? widget.groupId;
    final code = await _db.createInvite(groupId: groupId);
    if (!mounted) return;
    final installUrl =
        '${AppConstants.appWebLink}/install.html?invite=$code&groupId=$groupId&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'دعوة للانضمام إلى عائلتنا على Home Budgets\n\n'
        'افتح الرابط التالي وادخل اسمك للانضمام:\n$installUrl\n\n'
        'هذا الرابط للاستخدام مرة واحدة فقط (كود: $code).\n'
        'افتح نسخة الويب مباشرة على أندرويد أو آيفون بدون تثبيت.\n\n'
        'رابط APK الاختياري لأندرويد:\n${AppConstants.androidDownloadLink}';
    await Clipboard.setData(ClipboardData(text: message));
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'تم نسخ رابط التطبيق والدعوة. افتح واتساب والصقه لأي فرد.')),
      );
    }
  }

  Future<void> _shareNewFamilyTrial() async {
    final installUrl =
        '${AppConstants.appWebLink}/install.html?mode=newFamily&reset=1&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'جرّب Home Budgets وأنشئ عائلتك أنت\n\n'
        'افتح الرابط التالي:\n$installUrl\n\n'
        'افتح نسخة الويب مباشرة على أندرويد أو آيفون بدون تثبيت.\n'
        'APK اختياري لأندرويد فقط لو تريد تطبيق مثبت أو صوت أفضل.\n\n'
        'هذا الرابط للتجربة وإنشاء عائلة جديدة، وليس للانضمام لعائلتنا.';
    await Clipboard.setData(ClipboardData(text: message));
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('تم نسخ رابط التجربة. افتح واتساب والصقه لمن تريد.')),
      );
    }
  }

  Future<void> _startRecording() async {
    if (_isRecording || _isSending || _isPreparingVoice || _isConfirmingVoice) {
      return;
    }
    final available = await _voiceService.initialize(
      onError: (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('مشكلة في الميكروفون: $error')),
          );
        }
      },
    );
    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(_voiceService.lastError ??
                  'المايك غير متاح أو لم يتم منح الإذن')),
        );
      }
      return;
    }
    _textController.clear();
    setState(() {
      _isRecording = true;
      _lastParsedPreview = null;
    });
    try {
      await _voiceService.startListening(
        (result, isFinal) {
          _textController.text = result;
          _textController.selection =
              TextSelection.fromPosition(TextPosition(offset: result.length));
          _updateParsedPreview(result);
        },
        onError: (error) {
          if (mounted) {
            setState(() => _isRecording = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('لم أستطع سماع الرسالة: $error')),
            );
          }
        },
        onStatus: (status) {
          if ((status == 'done' || status == 'notListening') && mounted) {
            setState(() => _isRecording = false);
          }
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted && _isRecording && !_voiceService.isListening) {
        setState(() => _isRecording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'الميكروفون أخذ الإذن لكن خدمة التعرف الصوتي لم تبدأ. حدّث Google Speech Services أو استخدم ميكروفون الكيبورد/الكتابة.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRecording = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر بدء التسجيل الصوتي: $e')),
      );
    }
  }

  /// Stop dictation. The transcribed text is already in the input box (filled
  /// live while listening); the user reviews it and taps SEND. The mic never
  /// sends on its own — one consistent flow everywhere.
  Future<void> _stopVoice() async {
    await _voiceService.stopListening();
    if (mounted) setState(() => _isRecording = false);
  }

  void _updateParsedPreview(String value) {
    final parsedItems = AIService.parseExpenseMessages(value,
        categories: context.read<BudgetProvider>().categories);
    if (parsedItems.length > 1) {
      final total = parsedItems
          .where((item) => item['isExpense'] == true)
          .fold<double>(0, (sum, item) => sum + (item['amount'] as double));
      final preview =
          'سيتم تسجيل ${parsedItems.length} مصروفات بإجمالي ${formatMoney(total)} ج';
      if (_lastParsedPreview != preview) {
        setState(() => _lastParsedPreview = preview);
      }
      return;
    }
    final parsed = parsedItems.length == 1 ? parsedItems.first : null;
    if (parsed == null) {
      if (_lastParsedPreview != null) setState(() => _lastParsedPreview = null);
      return;
    }
    final amount = parsed['amount'] as double;
    final category = parsed['category'] as String;
    final isExpense = parsed['isExpense'] as bool;
    final label = isExpense ? 'سيتم تسجيل مصروف' : 'سيتم تسجيل دخل';
    final preview = '$label: ${formatMoney(amount)} ج — $category';
    if (_lastParsedPreview != preview) {
      setState(() => _lastParsedPreview = preview);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final budget = context.watch<BudgetProvider>();
    final notifications = context.watch<NotificationProvider>();
    final avatars = context.watch<AvatarProvider>();
    final user = auth.user;
    // Admin sees the family total; a member sees only their own wallet.
    final isMemberView = user != null && !user.isAdmin;
    final visibleBalance = !isMemberView
        ? budget.balance
        : budget.wallets
            .where((w) => w.isMemberWallet && w.ownerId == user.id)
            .fold<double>(0, (s, w) => s + w.balance);
    final nowMonth = DateTime.now();
    final visibleExpenses = !isMemberView
        ? budget.totalExpenses
        : budget.transactions
            .where((t) =>
                t.isExpense &&
                t.userId == user.id &&
                t.date.year == nowMonth.year &&
                t.date.month == nowMonth.month)
            .fold<double>(0, (s, t) => s + t.amount);
    // Admin sees the whole feed. A member sees: their own messages, messages
    // directed to them, and admin "send to all" broadcasts (admin-authored,
    // no specific target). A member's own untargeted message is implicitly to
    // the admin, so it must NOT leak to other members — hence the broadcast
    // rule requires an ADMIN sender. System money lines stay scoped as before.
    final adminIds =
        _members.where((m) => m.isAdmin).map((m) => m.id).toSet();
    bool isAdminBroadcast(ChatMessage m) =>
        adminIds.contains(m.senderId) &&
        m.type != MessageType.system &&
        (m.targetUserId == null || m.targetUserId!.isEmpty);
    final visibleMessages = (user == null || user.isAdmin)
        ? chat.messages
        : chat.messages
            .where((m) =>
                m.senderId == user.id ||
                m.targetUserId == user.id ||
                isAdminBroadcast(m))
            .toList();

    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: _openAccountDialog,
            child: _UserAvatar(
                name: user?.name ?? widget.groupName,
                photoBytes: avatars.bytesFor(user?.id),
                radius: 20),
          ),
        ),
        title: GestureDetector(
          onTap: () {
            if (user == null) return;
            if (user.isAdmin) {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        GroupSettingsScreen(groupId: widget.groupId)),
              );
            } else {
              // Members open their own wallet, not the family settings.
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MemberDetailScreen(
                      groupId: widget.groupId, member: user, selfView: true),
                ),
              );
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.groupName, style: const TextStyle(fontSize: 18)),
              Text(
                '${user?.name ?? ''} • ${formatMoney(visibleBalance)} ج',
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const Text(
                AppConstants.appVersion,
                style: TextStyle(fontSize: 9, color: Colors.white54),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'إشعارات العائلة',
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_rounded),
                if (notifications.unreadCount > 0)
                  Positioned(
                    right: -5,
                    top: -5,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                      child: Text(
                        notifications.unreadCount > 9
                            ? '9+'
                            : '${notifications.unreadCount}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => NotificationsScreen(groupId: widget.groupId)),
            ),
          ),
          IconButton(
            tooltip: 'أفراد العائلة',
            icon: const Icon(Icons.people_alt_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => MembersScreen(groupId: widget.groupId)),
            ),
          ),
          IconButton(
            tooltip: 'التقارير',
            icon: const Icon(Icons.analytics_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => AnalyticsScreen(groupId: widget.groupId)),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'المزيد',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) => _onMenuSelected(value),
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'invite',
                child: _MenuRow(
                    icon: Icons.person_add_alt_1_rounded,
                    label: 'دعوة / مشاركة'),
              ),
              if (user?.isAdmin == true)
                const PopupMenuItem(
                  value: 'teams',
                  child: _MenuRow(icon: Icons.groups_2_rounded, label: 'الفرق'),
                ),
              if (user?.isAdmin == true)
                const PopupMenuItem(
                  value: 'settings',
                  child: _MenuRow(
                      icon: Icons.settings_rounded, label: 'الإعدادات'),
                ),
              const PopupMenuItem(
                value: 'switch',
                child: _MenuRow(
                    icon: Icons.swap_horiz_rounded, label: 'تبديل الحساب'),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: _MenuRow(
                    icon: Icons.logout_rounded, label: 'تسجيل الخروج'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_updateVersion != null && !_updateDismissed)
            Material(
              color: AppTheme.gold,
              child: InkWell(
                onTap: _doUpdate,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.system_update_rounded,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'نسخة جديدة متاحة ($_updateVersion). اضغط للتحديث.',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13),
                        ),
                      ),
                      TextButton(
                        onPressed: _doUpdate,
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            visualDensity: VisualDensity.compact),
                        child: const Text('تحديث',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      InkWell(
                        onTap: () => setState(() => _updateDismissed = true),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppTheme.primaryDark,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _SummaryItem(
                  label: isMemberView
                      ? 'مصروفاتي هذا الشهر'
                      : 'مصروفات العائلة هذا الشهر',
                  amount: visibleExpenses,
                  color: AppTheme.expenseRed,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ExpensesOverviewScreen(groupId: widget.groupId),
                    ),
                  ),
                ),
                _SummaryItem(
                  label: isMemberView ? 'رصيدي' : 'رصيد المحافظ',
                  amount: visibleBalance,
                  color: AppTheme.incomeGreen,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          WalletsOverviewScreen(groupId: widget.groupId),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_isSending ||
              _isSyncingFamilyData ||
              _isRecording ||
              _isPreparingVoice ||
              budget.loading)
            Container(
              width: double.infinity,
              color: AppTheme.systemMessage,
              child: Column(
                children: [
                  const LinearProgressIndicator(minHeight: 2),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                    child: Text(
                      _isSending
                          ? 'جاري حفظ المصروف ومزامنته مع العائلة...'
                          : budget.loading
                              ? 'جاري حفظ حدود المصروفات...'
                              : _isPreparingVoice
                                  ? 'جاري تجهيز التسجيل الصوتي...'
                                  : _isRecording
                                      ? 'جاري الاستماع... اضغط زر الميكروفون مرة أخرى عند الانتهاء.'
                                      : 'جاري تحديث بيانات العائلة...',
                      textDirection: ui.TextDirection.rtl,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.brown,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: chat.loading
                ? const Center(child: CircularProgressIndicator())
                : visibleMessages.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.chat_bubble_outline_rounded,
                                size: 64, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              'لا توجد رسائل بعد\nاكتب المصروف ثم أرسله بالسهم',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(fontSize: 16, color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        itemCount: visibleMessages.length,
                        itemBuilder: (context, index) {
                          final msg = visibleMessages[index];
                          return ChatBubble(
                            message: msg,
                            isMe: msg.senderId == user?.id,
                            onLongPress: () => _showMessageActions(msg, user),
                          );
                        },
                      ),
          ),
          _QuickExpenseHints(onPick: _putTextInInput),
          if (chat.hasMoreReport(widget.groupId))
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: ActionChip(
                  avatar: const Icon(Icons.navigate_next_rounded),
                  label: const Text('التالي من التقرير'),
                  onPressed: () => _sendMessage('التالي'),
                ),
              ),
            ),
          if (_lastParsedPreview != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: AppTheme.systemMessage,
              child: Text(
                _lastParsedPreview!,
                textDirection: ui.TextDirection.rtl,
                style: const TextStyle(fontSize: 13, color: Colors.brown),
              ),
            ),
          if (_replyTo != null) _replyBanner(),
          MessageInput(
            controller: _textController,
            onSend: () => _sendMessage(),
            // Press-and-hold: hold the mic to dictate, release to stop — the
            // text lands in the box, then you tap SEND. The mic never sends by
            // itself. (Expense-permission is enforced on save, not here.)
            onMicStart: () => unawaited(_startRecording()),
            onMicStop: () => unawaited(_stopVoice()),
            isRecording: _isRecording,
            isSending: _isSending,
            enabled: !budget.loading,
            onChanged: _updateParsedPreview,
          ),
        ],
      ),
    );
  }
}

class _UserAvatar extends StatelessWidget {
  final String name;
  final Uint8List? photoBytes;
  final double radius;

  const _UserAvatar({required this.name, this.photoBytes, required this.radius});

  @override
  Widget build(BuildContext context) {
    final bytes = photoBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: MemoryImage(bytes));
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppTheme.primaryLight,
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppTheme.primaryGreen),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}

class _QuickExpenseHints extends StatelessWidget {
  final ValueChanged<String> onPick;
  const _QuickExpenseHints({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final hints = [
      'تقرير آخر أسبوع',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          children: hints
              .map(
                (hint) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ActionChip(
                    label: Text(hint, textDirection: ui.TextDirection.rtl),
                    onPressed: () => onPick(hint),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;
  final VoidCallback? onTap;

  const _SummaryItem({
    required this.label,
    required this.amount,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            if (onTap != null) ...[
              const SizedBox(width: 3),
              const Icon(Icons.unfold_more_rounded,
                  size: 13, color: Colors.white38),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${formatMoney(amount)} ج',
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 15),
        ),
      ],
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: content,
      ),
    );
  }
}
