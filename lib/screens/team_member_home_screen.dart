import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../config/constants.dart';
import '../config/theme.dart';
import '../models/chat_message_model.dart';
import '../models/team_model.dart';
import '../models/transaction_model.dart';
import '../models/user_model.dart';
import '../models/wallet_entry_model.dart';
import '../models/wallet_model.dart';
import '../providers/auth_provider.dart';
import '../providers/avatar_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/notification_provider.dart';
import '../services/database_service.dart';
import '../services/voice_service.dart';
import '../utils/money_format.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/expense_confirm_dialog.dart';
import '../widgets/wallet_ledger_table.dart';
import 'notifications_screen.dart';
import 'team_analytics_screen.dart';

class TeamMemberHomeScreen extends StatefulWidget {
  final String groupId;
  final String teamId;

  const TeamMemberHomeScreen({
    super.key,
    required this.groupId,
    required this.teamId,
  });

  @override
  State<TeamMemberHomeScreen> createState() => _TeamMemberHomeScreenState();
}

class _TeamMemberHomeScreenState extends State<TeamMemberHomeScreen> {
  final _db = DatabaseService();
  final _voice = VoiceService();
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _uuid = const Uuid();
  TeamModel? _team;
  WalletModel? _wallet;
  List<TransactionModel> _txns = const [];
  List<UserModel> _teammates = const [];
  UserModel? _admin;
  // The team chat feed (chat messages + expense bubbles) — the worker's home
  // is chat-first, exactly like a family member's main screen.
  List<ChatMessage> _messages = const [];
  StreamSubscription<List<ChatMessage>>? _chatSub;
  ChatMessage? _replyTo;
  bool _loading = true;
  bool _saving = false;
  bool _isRecording = false;
  bool _walletExpanded = false;
  String? _updateVersion;
  bool _updateDismissed = false;
  final Map<String, Future<List<WalletEntryModel>>> _entryFutures = {};

  Future<List<WalletEntryModel>> _ledgerFor(WalletModel w) {
    final key = '${w.id}|${w.updatedAt?.toIso8601String() ?? ''}|${w.balance}';
    return _entryFutures.putIfAbsent(
        key, () => _db.getWalletEntriesSync(widget.groupId, w.id));
  }

  @override
  void initState() {
    super.initState();
    _load();
    _chatSub = _db
        .watchTeamChatMessages(widget.groupId, widget.teamId)
        .listen((msgs) {
      if (!mounted) return;
      setState(() => _messages = msgs);
    });
    _db.checkForUpdate().then((v) {
      if (mounted && v != null) setState(() => _updateVersion = v);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final userId = context.read<AuthProvider>().user?.id;
      if (userId != null) {
        context
            .read<NotificationProvider>()
            .subscribe(widget.groupId, userId, isAdmin: false);
        context.read<AvatarProvider>().load(widget.groupId);
      }
    });
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    _scrollController.dispose();
    _voice.dispose();
    _controller.dispose();
    super.dispose();
  }

  // Press-and-hold mic: hold to record (live text fills the box), release to
  // stop, then the user reviews and taps send.
  Future<void> _startMic() async {
    if (_isRecording || _saving) return;
    final ok = await _voice.initialize(
      onError: (e) {
        if (mounted) _snack('مشكلة في الميكروفون: $e');
      },
    );
    if (!ok) {
      _snack(_voice.lastError ?? 'الميكروفون غير متاح أو لم يُمنح الإذن.');
      return;
    }
    _controller.clear();
    if (mounted) setState(() => _isRecording = true);
    await _voice.startListening(
      (result, isFinal) {
        _controller.text = result;
        _controller.selection =
            TextSelection.fromPosition(TextPosition(offset: result.length));
      },
      onError: (e) {
        if (mounted) {
          setState(() => _isRecording = false);
          _snack('لم أستطع سماع الرسالة: $e');
        }
      },
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') && mounted) {
          setState(() => _isRecording = false);
        }
      },
    );
  }

  Future<void> _stopMic() async {
    await _voice.stopListening();
    if (mounted) setState(() => _isRecording = false);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final team = await _db.getTeamById(widget.groupId, widget.teamId);
    final me = context.read<AuthProvider>().user;
    final myId = me?.id;
    // The worker's own wallet (a member wallet tagged with this team).
    WalletModel? wallet;
    if (myId != null) {
      final wallets = await _db.getWalletsSync(widget.groupId);
      for (final w in wallets) {
        if (w.isMemberWallet && w.ownerId == myId) {
          wallet = w;
          break;
        }
      }
    }
    // Self-heal on every refresh: a wallet-ledger entry proves an expense
    // happened even if its transaction record never got saved (or drifted
    // from an old id/team) — fold it back in before loading.
    if (me != null && wallet != null) {
      await _db.reconcileMemberWallet(widget.groupId, me, wallet);
    }
    final all = team == null
        ? const <TransactionModel>[]
        : await _db.getTeamTransactions(widget.groupId, widget.teamId);
    // A worker sees only their OWN expenses, not the whole team's.
    final txns =
        myId == null ? all : all.where((t) => t.userId == myId).toList();
    // Teammates + the admin — social visibility only, wallet access stays
    // scoped to just [wallet] above.
    var teammates = const <UserModel>[];
    UserModel? admin;
    if (team != null) {
      final workers = await _db.getTeamWorkers(widget.groupId, team.id);
      teammates = workers.where((m) => m.id != myId).toList();
      admin = await _db.getMember(widget.groupId, team.ownerId);
    }
    if (!mounted) return;
    setState(() {
      _team = team;
      _wallet = wallet;
      _txns = txns;
      _teammates = teammates;
      _admin = admin;
      _loading = false;
    });
  }

  /// The one input handles BOTH — like a family member's main screen: if the
  /// text parses as an expense it's recorded (wallet + reports) and shows as an
  /// expense bubble; otherwise it's sent as a plain team chat message.
  Future<void> _submit() async {
    final text = _controller.text.trim();
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    final team = _team;
    if (text.isEmpty || user == null || team == null || _saving) return;

    final chat = context.read<ChatProvider>();
    // Not a family member — BudgetProvider is never loaded for this session,
    // so categories are fetched directly instead of via the provider.
    final categories = await _db.getCategoriesSync(widget.groupId);
    var resolved = (await chat.resolveExpenseMessages(
            widget.groupId, text, user,
            categories: categories))
        .where((r) => r.isExpense)
        .toList();

    // Not an expense → it's a chat message.
    if (resolved.isEmpty) {
      final replyTo = _replyTo;
      _controller.clear();
      if (mounted) setState(() => _replyTo = null);
      setState(() => _saving = true);
      try {
        await _db.sendTeamChatMessage(
          widget.groupId,
          team.id,
          ChatMessage(
            id: _uuid.v4(),
            groupId: widget.groupId,
            senderId: user.id,
            senderName: user.name,
            senderAvatar: user.photoUrl,
            type: MessageType.text,
            content: text,
            timestamp: DateTime.now(),
            replyToId: replyTo?.id,
            replyToSender: replyTo?.senderName,
            replyToText: replyTo?.content,
          ),
        );
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }

    // Mandatory confirm-before-save, same dialog the family chat uses — shows
    // the final resolved category for every item with a change-type control.
    final confirmedItems =
        await confirmResolvedExpenses(context, resolved, categories);
    if (confirmedItems == null) return;
    resolved = confirmedItems;

    final total = resolved.fold<double>(0, (sum, r) => sum + r.amount);
    final wallet = _wallet;
    if (wallet != null && total > wallet.balance + 0.005) {
      _snack('الرصيد غير كافٍ في محفظتك. المتاح ${formatMoney(wallet.balance)} ج.');
      return;
    }

    setState(() => _saving = true);
    try {
      final warning = await chat.commitResolvedExpenses(
        widget.groupId,
        user,
        text,
        resolved,
        wallet: wallet,
        team: team,
      );
      if (warning != null) _snack(warning);
      _controller.clear();
      if (mounted) setState(() => _replyTo = null);
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Web: reload to the new build. Native: open the APK download page.
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
      _snack('تعذّر فتح رابط التحديث.');
    }
  }

  Widget _updateBanner() {
    return Material(
      color: AppTheme.gold,
      child: InkWell(
        onTap: _doUpdate,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  child:
                      Icon(Icons.close_rounded, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Self-service profile: photo + name, same capability family members get
  /// from their own chat header.
  Future<void> _openAccountSheet() async {
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
            _WorkerAvatar(
                name: user.name, photoBytes: avatars.bytesFor(user.id), radius: 42),
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
              },
              icon: const Icon(Icons.photo_camera_back_rounded),
              label: const Text('رفع صورة للحساب'),
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
                  if (mounted) await _load();
                },
                icon: const Icon(Icons.edit_rounded),
                label: const Text('تعديل اسمي'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _changeMyPhone(user);
                },
                icon: const Icon(Icons.phone_android_rounded),
                label: const Text('تغيير رقم الهاتف'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Self-service identity phone change. Requires typing the new number twice
  /// given the risk — this migrates the worker's transactions, notifications,
  /// and team-chat messages to the new number. Old messages/transactions keep
  /// showing the worker's current NAME (unaffected); only the login phone and
  /// the id it's stored under change.
  Future<void> _changeMyPhone(UserModel user) async {
    final phone1C = TextEditingController();
    final phone2C = TextEditingController();
    final newPhone = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تغيير رقم الهاتف'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('رقمك الحالي: ${user.phone ?? ''}',
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: phone1C,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'الرقم الجديد', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phone2C,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'أعد كتابة الرقم الجديد',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            const Text(
              'سيتم نقل مصروفاتك وإشعاراتك ومحادثة الفريق إلى الرقم الجديد. اسمك يبقى كما هو في السجل القديم. لا يمكن التراجع تلقائيًا.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final a = phone1C.text.trim();
              final b = phone2C.text.trim();
              if (a.isEmpty || a != b) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text('الرقمان غير متطابقين أو فارغان.')));
                return;
              }
              Navigator.pop(ctx, a);
            },
            child: const Text('تأكيد النقل'),
          ),
        ],
      ),
    );
    phone1C.dispose();
    phone2C.dispose();
    if (newPhone == null || !mounted) return;
    final err = await _db.changeJoinedMemberPhone(widget.groupId, user, newPhone);
    if (!mounted) return;
    if (err != null) {
      _snack(err);
      return;
    }
    // The worker's OWN id just changed — their old member doc is gone, so the
    // live session must be pointed at the new one directly (a normal
    // "refresh by my current id" would look up a now-deleted doc).
    final fresh = await _db.getMemberByPhone(widget.groupId, newPhone);
    if (fresh != null && mounted) {
      await context.read<AuthProvider>().replaceCurrentUser(fresh);
    }
    _snack('تم تغيير رقمك بنجاح.');
    await _load();
  }

  /// Long-press menu on a message in the feed: reply + copy for anything, plus
  /// change-type/delete for MY OWN expense bubbles (same as a family member).
  Future<void> _showMessageActions(ChatMessage msg) async {
    if (msg.isDeleted || msg.type == MessageType.system) return;
    final myId = context.read<AuthProvider>().user?.id;
    final canEditExpense = msg.type == MessageType.expense &&
        msg.senderId == myId &&
        (msg.transactionId ?? '').isNotEmpty;
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
                title: const Text('حذف المصروف',
                    style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (action == 'reply') {
      if (mounted) setState(() => _replyTo = msg);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: msg.content));
      _snack('تم نسخ النص');
    } else if (action == 'recat') {
      await _recategorizeMessage(msg);
    } else if (action == 'delete') {
      await _deleteMessage(msg);
    }
  }

  Future<void> _recategorizeMessage(ChatMessage msg) async {
    final txId = msg.transactionId;
    if (txId == null || txId.isEmpty) return;
    final categories = (await _db.getCategoriesSync(widget.groupId))
        .where((c) => !c.isIncome)
        .toList();
    if (categories.isEmpty || !mounted) return;
    final chosen = await pickCategory(context, categories);
    if (chosen == null || !mounted) return;
    await _db.recategorizeExpense(widget.groupId, txId, chosen.name);
    await _db.recategorizeTeamExpenseMessage(
        widget.groupId, widget.teamId, txId, chosen.name);
    // Money-record edits are never silent to the admin.
    final user = context.read<AuthProvider>().user;
    final admin = _admin;
    if (user != null && admin != null) {
      await _db.notifyMultiple(
        widget.groupId,
        title: 'تغيير نوع مصروف فريق ${_team?.name ?? ''}',
        body:
            '${user.name} غيّر نوع ${formatMoney(msg.amount ?? 0)} ج من "${msg.category ?? ''}" إلى "${chosen.name}"',
        actorId: user.id,
        actorName: user.name,
        targetUserIds: [user.id, admin.id],
        teamId: widget.teamId,
      );
    }
    _snack('تم تغيير النوع إلى "${chosen.name}"');
    await _load();
  }

  Future<void> _deleteMessage(ChatMessage msg) async {
    final txId = msg.transactionId;
    if (txId == null || txId.isEmpty) return;
    final user = context.read<AuthProvider>().user;
    final deleted = await _db.deleteTransaction(
      widget.groupId,
      txId,
      byName: user?.name,
      byPhone: user?.phone,
    );
    if (deleted == null) {
      _snack('لم أجد المصروف. ربما تم حذفه من قبل.');
      return;
    }
    await _db.markTeamExpenseMessageDeleted(
        widget.groupId, widget.teamId, txId);
    final admin = _admin;
    if (user != null && admin != null) {
      await _db.notifyMultiple(
        widget.groupId,
        title: 'حذف مصروف فريق ${_team?.name ?? ''}',
        body:
            '${user.name} حذف ${formatMoney(deleted.amount)} ج — ${deleted.category}',
        actorId: user.id,
        actorName: user.name,
        targetUserIds: [user.id, admin.id],
        teamId: widget.teamId,
      );
    }
    _snack('تم حذف المصروف وإرجاع أثره إلى محفظتك');
    await _load();
  }

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

  Future<void> _callPhone(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (!await launchUrl(uri)) _snack('تعذّر فتح تطبيق الاتصال.');
  }

  /// Social visibility only — teammates + the admin. Wallet access is
  /// unaffected: a worker still only ever sees/uses their OWN wallet.
  Future<void> _showTeamPeopleSheet() async {
    final team = _team;
    if (team == null) return;
    final admin = _admin;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          shrinkWrap: true,
          children: [
            Text('أعضاء ${team.name}',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.shield_rounded, color: AppTheme.gold),
              title: Text(team.ownerName),
              subtitle: Text('قائد العائلة'
                  '${(admin?.phone ?? '').isEmpty ? '' : ' — ${admin!.phone}'}'),
              trailing: (admin?.phone ?? '').isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'اتصال',
                      icon: const Icon(Icons.call_rounded,
                          color: AppTheme.incomeGreen),
                      onPressed: () => _callPhone(admin!.phone!),
                    ),
            ),
            const Divider(height: 24),
            if (_teammates.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('لا يوجد زملاء آخرون في الفريق بعد.'),
              )
            else
              ..._teammates.map((m) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.engineering_rounded),
                    title: Text(m.name),
                  )),
          ],
        ),
      ),
    );
  }

  Widget _walletCard() {
    final wallet = _wallet;
    final now = DateTime.now();
    final monthSpent = _txns
        .where((t) =>
            t.isExpense && t.date.year == now.year && t.date.month == now.month)
        .fold<double>(0, (s, t) => s + t.amount);
    final limit = wallet?.limit ?? 0;
    final overCap = limit > 0 && monthSpent > limit;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: wallet == null
                ? null
                : () => setState(() => _walletExpanded = !_walletExpanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('الرصيد المتاح في محفظتي',
                            style:
                                TextStyle(color: Colors.black54, fontSize: 13)),
                      ),
                      if (wallet != null)
                        Icon(
                          _walletExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          color: Colors.black45,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    wallet == null
                        ? 'لا توجد محفظة بعد'
                        : '${formatMoney(wallet.balance)} ج',
                    style: TextStyle(
                      color: (wallet?.balance ?? 0) < 0
                          ? Colors.red.shade700
                          : AppTheme.primaryDark,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (limit > 0) ...[
                    const Divider(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('إنفاق هذا الشهر',
                            style:
                                TextStyle(color: Colors.black54, fontSize: 13)),
                        Text(
                          '${formatMoney(monthSpent)} / ${formatMoney(limit)} ج',
                          style: TextStyle(
                            color:
                                overCap ? Colors.red.shade700 : Colors.black87,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    if (overCap)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            Icon(Icons.flag_rounded,
                                size: 16, color: Colors.red.shade700),
                            const SizedBox(width: 4),
                            Text('تجاوزت حد الإنفاق الشهري',
                                style: TextStyle(
                                    color: Colors.red.shade700, fontSize: 12)),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (_walletExpanded && wallet != null) ...[
            const Divider(height: 1),
            FutureBuilder<List<WalletEntryModel>>(
              future: _ledgerFor(wallet),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: LinearProgressIndicator(minHeight: 2),
                  );
                }
                return buildWalletLedgerTable(
                    snap.data ?? const <WalletEntryModel>[]);
              },
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final notifications = context.watch<NotificationProvider>();
    final avatars = context.watch<AvatarProvider>();
    final user = auth.user;
    final team = _team;
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: _openAccountSheet,
            child: _WorkerAvatar(
                name: user?.name ?? '', photoBytes: avatars.bytesFor(user?.id)),
          ),
        ),
        title: Text(team == null ? 'فريق' : team.name),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (team != null)
            IconButton(
              tooltip: 'أعضاء الفريق',
              onPressed: _showTeamPeopleSheet,
              icon: const Icon(Icons.groups_2_rounded),
            ),
          if (team != null)
            IconButton(
              tooltip: 'تقاريري',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TeamAnalyticsScreen(
                    groupId: widget.groupId,
                    teamId: team.id,
                    teamName: team.name,
                  ),
                ),
              ),
              icon: const Icon(Icons.bar_chart_rounded),
            ),
          IconButton(
            tooltip: 'إشعاراتي',
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
            tooltip: 'تبديل الحساب',
            onPressed: () async {
              await auth.switchAccount();
              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(
                    context, '/auth', (route) => false);
              }
            },
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
          IconButton(
            tooltip: 'خروج',
            onPressed: () async {
              await auth.signOut();
              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(
                    context, '/auth', (route) => false);
              }
            },
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : team == null
              ? const Center(child: Text('لم أجد هذا الفريق'))
              : Column(
                  children: [
                    if (_updateVersion != null && !_updateDismissed)
                      _updateBanner(),
                    Container(
                      width: double.infinity,
                      color: AppTheme.primaryGreen,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: _walletCard(),
                    ),
                    Expanded(
                      child: _messages.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text(
                                  'اكتب رسالة للفريق، أو سجّل مصروفًا مثل: دفعت 100 بنزين',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              reverse: true,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 8),
                              itemCount: _messages.length,
                              itemBuilder: (context, index) {
                                final msg = _messages[index];
                                return ChatBubble(
                                  message: msg,
                                  isMe: msg.senderId == user?.id,
                                  onLongPress: () => _showMessageActions(msg),
                                );
                              },
                            ),
                    ),
                    if (_replyTo != null) _replyBanner(),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Listener(
                              onPointerDown: _saving
                                  ? null
                                  : (_) => unawaited(_startMic()),
                              onPointerUp: (_) => unawaited(_stopMic()),
                              onPointerCancel: (_) => unawaited(_stopMic()),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Icon(
                                  _isRecording
                                      ? Icons.mic_rounded
                                      : Icons.mic_none_rounded,
                                  color: _isRecording
                                      ? Colors.red
                                      : AppTheme.primaryGreen,
                                ),
                              ),
                            ),
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                minLines: 1,
                                maxLines: 3,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _submit(),
                                decoration: const InputDecoration(
                                  hintText: 'رسالة للفريق أو مصروف…',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: _saving ? null : _submit,
                              child: _saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.send_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _WorkerAvatar extends StatelessWidget {
  final String name;
  final Uint8List? photoBytes;
  final double radius;

  const _WorkerAvatar({required this.name, this.photoBytes, this.radius = 20});

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
