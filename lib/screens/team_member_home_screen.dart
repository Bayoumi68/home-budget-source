import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/theme.dart';
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
import '../widgets/expense_confirm_dialog.dart';
import '../widgets/wallet_ledger_table.dart';
import 'notifications_screen.dart';
import 'team_analytics_screen.dart';
import 'team_chat_screen.dart';

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
  TeamModel? _team;
  WalletModel? _wallet;
  List<TransactionModel> _txns = const [];
  List<UserModel> _teammates = const [];
  UserModel? _admin;
  bool _loading = true;
  bool _saving = false;
  bool _isRecording = false;
  bool _walletExpanded = false;
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
    _voice.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggleMic() async {
    if (_isRecording) {
      await _voice.stopListening();
      if (mounted) setState(() => _isRecording = false);
      return;
    }
    final ok = await _voice.initialize(
      onError: (e) {
        if (mounted) _snack('مشكلة في الميكروفون: $e');
      },
    );
    if (!ok) {
      _snack(_voice.lastError ?? 'الميكروفون غير متاح أو لم يُمنح الإذن.');
      return;
    }
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
    if (resolved.isEmpty) {
      _snack('اكتب مصروف واضح مثل: دفعت 100 بنزين');
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
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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

  /// Long-press menu for one of MY OWN expenses (this list is already
  /// filtered to `_txns` where `userId == myId` — see [_load]): change its
  /// category or delete it, same actions a family member gets in the chat.
  Future<void> _showExpenseActions(TransactionModel txn) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.category_rounded),
              title: const Text('تغيير النوع'),
              onTap: () => Navigator.pop(ctx, 'recat'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: Colors.red),
              title: const Text('حذف المصروف', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'recat') {
      await _recategorizeTxn(txn);
    } else if (action == 'delete') {
      await _deleteTxn(txn);
    }
  }

  Future<void> _recategorizeTxn(TransactionModel txn) async {
    final categories =
        (await _db.getCategoriesSync(widget.groupId)).where((c) => !c.isIncome).toList();
    if (categories.isEmpty || !mounted) return;
    final chosen = await pickCategory(context, categories);
    if (chosen == null || !mounted) return;
    await _db.recategorizeExpense(widget.groupId, txn.id, chosen.name);
    // Same visibility as deleting an expense — money-record edits are
    // never silent to the admin.
    final user = context.read<AuthProvider>().user;
    final admin = _admin;
    if (user != null && admin != null) {
      await _db.notifyMultiple(
        widget.groupId,
        title: 'تغيير نوع مصروف فريق ${_team?.name ?? ''}',
        body:
            '${user.name} غيّر نوع ${formatMoney(txn.amount)} ج من "${txn.category}" إلى "${chosen.name}"',
        actorId: user.id,
        actorName: user.name,
        targetUserIds: [user.id, admin.id],
      );
    }
    _snack('تم تغيير النوع إلى "${chosen.name}"');
    await _load();
  }

  Future<void> _deleteTxn(TransactionModel txn) async {
    final user = context.read<AuthProvider>().user;
    final deleted = await _db.deleteTransaction(
      widget.groupId,
      txn.id,
      byName: user?.name,
      byPhone: user?.phone,
    );
    if (deleted == null) {
      _snack('لم أجد المصروف. ربما تم حذفه من قبل.');
      return;
    }
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
      );
    }
    _snack('تم حذف المصروف وإرجاع أثره إلى محفظتك');
    await _load();
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
              tooltip: 'محادثة الفريق',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TeamChatScreen(
                    groupId: widget.groupId,
                    teamId: team.id,
                    teamName: team.name,
                  ),
                ),
              ),
              icon: const Icon(Icons.chat_bubble_rounded),
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
                    Container(
                      width: double.infinity,
                      color: AppTheme.primaryGreen,
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user?.name ?? 'عضو فريق',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'فريق: ${team.name}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'مصروفات الفريق تُخصم من محفظتك الخاصة.',
                            style: TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 12),
                          _walletCard(),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _txns.isEmpty
                          ? const Center(
                              child: Text('لا توجد مصروفات للفريق بعد'),
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView.separated(
                                padding: const EdgeInsets.all(16),
                                itemCount: _txns.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final txn = _txns[index];
                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading:
                                        const Icon(Icons.receipt_long_rounded),
                                    title: Text(
                                        '${txn.category} - ${formatMoney(txn.amount)} ج'),
                                    subtitle: Text(
                                      '${txn.userName}\n${DateFormat('yyyy/MM/dd - HH:mm').format(txn.date)}',
                                    ),
                                    isThreeLine: true,
                                    onLongPress: () => _showExpenseActions(txn),
                                  );
                                },
                              ),
                            ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: _saving ? null : _toggleMic,
                              tooltip: _isRecording ? 'إيقاف' : 'تحدّث',
                              icon: Icon(
                                _isRecording
                                    ? Icons.stop_circle_rounded
                                    : Icons.mic_rounded,
                                color: _isRecording
                                    ? Colors.red
                                    : AppTheme.primaryGreen,
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
                                  hintText: 'اكتب أو تحدّث بمصروف الفريق',
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
