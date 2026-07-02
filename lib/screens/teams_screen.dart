import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/constants.dart';
import '../config/theme.dart';
import '../models/team_model.dart';
import '../models/transaction_model.dart';
import '../models/user_model.dart';
import '../models/wallet_entry_model.dart';
import '../models/wallet_model.dart';
import '../providers/auth_provider.dart';
import '../services/database_service.dart';
import '../widgets/wallet_ledger_table.dart';
import 'team_chat_screen.dart';

class TeamsScreen extends StatefulWidget {
  final String groupId;
  const TeamsScreen({super.key, required this.groupId});

  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  final _db = DatabaseService();
  final _money = NumberFormat('#,###');
  bool _loading = true;
  String? _error;
  List<UserModel> _members = [];
  List<TeamModel> _teams = [];
  List<WalletModel> _wallets = [];
  final Map<String, List<TransactionModel>> _teamTxns = {};
  // Ledger expand/collapse + fetch cache — same pattern as the family-member
  // wallet view in group_settings_screen.dart / wallets_overview_screen.dart.
  final Set<String> _expandedWorkers = {};
  final Map<String, Future<List<WalletEntryModel>>> _entryFutures = {};

  Future<List<WalletEntryModel>> _entriesFor(WalletModel w) {
    final key = '${w.id}|${w.updatedAt?.toIso8601String() ?? ''}|${w.balance}';
    return _entryFutures.putIfAbsent(
        key, () => _db.getWalletEntriesSync(widget.groupId, w.id));
  }

  WalletModel? _walletFor(String memberId) {
    for (final w in _wallets) {
      if (w.isMemberWallet && w.ownerId == memberId) return w;
    }
    return null;
  }

  /// A worker's own wallet balance (a team is a rollup of these).
  double _memberBalance(String memberId) {
    for (final w in _wallets) {
      if (w.isMemberWallet && w.ownerId == memberId) return w.balance;
    }
    return 0;
  }

  /// The team's workers (their own member docs, tagged with this team).
  List<UserModel> _teamWorkers(TeamModel team) =>
      _members.where((m) => m.teamId == team.id).toList();

  double _teamBalance(TeamModel team) =>
      _teamWorkers(team).fold<double>(0, (s, m) => s + _memberBalance(m.id));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthProvider>();
      final user = auth.user;
      await _db.provisionMemberWallets(widget.groupId);
      // Self-heal: fold in any worker (or family member) transaction that a
      // ledger entry proves exists but never got saved, before loading data.
      await _db.reconcileAllMemberWallets(widget.groupId);
      final members = await _db.getMembersSync(widget.groupId);
      final wallets = await _db.getWalletsSync(widget.groupId);
      final teams = user == null
          ? <TeamModel>[]
          : await _db.getVisibleTeams(widget.groupId, user);
      final txnLists = await Future.wait(
        teams.map((team) => _db.getTeamTransactions(widget.groupId, team.id)),
      );
      final txns = <String, List<TransactionModel>>{};
      for (var i = 0; i < teams.length; i++) {
        txns[teams[i].id] = txnLists[i];
      }
      if (!mounted) return;
      setState(() {
        _members = members;
        _wallets = wallets;
        _teams = teams;
        _teamTxns
          ..clear()
          ..addAll(txns);
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذر تحميل الفرق الآن. حاول مرة أخرى.\n$e';
        _loading = false;
      });
    }
  }

  bool _canManageTeam(TeamModel team) {
    final user = context.read<AuthProvider>().user;
    if (user == null) return false;
    return team.canManage(user.id, isAdmin: user.isAdmin);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final canCreate = auth.user?.isAdmin == true ||
        auth.user?.canManageMembers == true ||
        auth.user?.canManageBudgets == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الفرق'),
        actions: [
          if (canCreate)
            IconButton(
              tooltip: 'إنشاء فريق',
              icon: const Icon(Icons.add_rounded),
              onPressed: _showTeamDialog,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            size: 48, color: AppTheme.expenseRed),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('إعادة المحاولة'),
                        ),
                      ],
                    ),
                  ),
                )
              : _teams.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.groups_2_rounded,
                                size: 54, color: AppTheme.primaryLight),
                            const SizedBox(height: 12),
                            const Text(
                              'لا توجد فرق بعد',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'أنشئ فريقًا مثل السيارات وحدد أعضاءه ورصيده.',
                              textAlign: TextAlign.center,
                            ),
                            if (canCreate) ...[
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: _showTeamDialog,
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('إنشاء فريق'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _teams.length,
                        itemBuilder: (context, index) =>
                            _buildTeamCard(_teams[index]),
                      ),
                    ),
    );
  }

  Widget _buildTeamCard(TeamModel team) {
    final txns = _teamTxns[team.id] ?? const <TransactionModel>[];
    final spent = _db.spentForTeam(txns);
    // Keyed by userId, not userName: a worker's rename must not split their
    // history into two buckets (userName on a transaction is a point-in-time
    // snapshot, unlike the always-current UserModel used to display it).
    final byMember = <String, double>{};
    for (final txn in txns.where((t) => t.isExpense)) {
      byMember[txn.userId] = (byMember[txn.userId] ?? 0) + txn.amount;
    }
    final canManage = _canManageTeam(team);

    final rollup = _teamBalance(team);

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: ExpansionTile(
        leading: const Icon(Icons.groups_2_rounded),
        title: Text(team.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
            'إجمالي أرصدة الأعضاء: ${_money.format(rollup)} ج — صرفوا: ${_money.format(spent)} ج'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          // Rollup: one line per WORKER = their own wallet balance (+ spend).
          ...(() {
            final workers = _teamWorkers(team);
            if (workers.isEmpty) {
              return [
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.engineering_rounded),
                  title: Text('لا يوجد عمّال في هذا الفريق بعد'),
                  subtitle: Text('اضغط "إضافة عامل" أو شارك دعوة الفريق.'),
                )
              ];
            }
            return workers.map((w) => _workerLedgerLine(team, w, byMember, canManage))
                .toList();
          })(),
          const Divider(height: 24),
          _buildTransactionsSection(team, txns, canManage),
          const Divider(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
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
                label: const Text('محادثة الفريق'),
              ),
              if (canManage) ...[
                OutlinedButton.icon(
                  onPressed: () => _addWorkerDialog(team),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: const Text('إضافة عامل'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.incomeGreen),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showTeamDialog(team: team),
                  icon: const Icon(Icons.edit_rounded),
                  label: const Text('تعديل الاسم'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _deleteTeam(team),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('حذف الفريق'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// A worker's row: name/contact + balance + admin actions, expandable in
  /// place to the same DR/CR ledger table family members already get.
  Widget _workerLedgerLine(TeamModel team, UserModel w,
      Map<String, double> byMember, bool canManage) {
    final memberSpent = byMember[w.id] ?? 0;
    final expanded = _expandedWorkers.contains(w.id);
    final wallet = _walletFor(w.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (expanded) {
              _expandedWorkers.remove(w.id);
            } else {
              _expandedWorkers.add(w.id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.engineering_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(w.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        'صرف: ${_money.format(memberSpent)} ج'
                        '${(w.phone ?? '').isEmpty ? '' : ' — ${w.phone}'}'
                        '${(w.email ?? '').isEmpty ? '' : '\n${w.email}'}',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Text('الرصيد ${_money.format(_memberBalance(w.id))} ج',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                if (canManage)
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'fund') _fundWorker(team, w, withdraw: false);
                      if (v == 'withdraw') _fundWorker(team, w, withdraw: true);
                      if (v == 'edit') _editWorker(team, w);
                      if (v == 'permissions') _showWorkerPermissionsDialog(w);
                      if (v == 'invite') _inviteWorker(team, w);
                      if (v == 'remove') _removeWorker(team, w);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'fund', child: Text('تمويل')),
                      PopupMenuItem(value: 'withdraw', child: Text('سحب')),
                      PopupMenuItem(
                          value: 'edit', child: Text('تعديل البيانات')),
                      PopupMenuItem(
                          value: 'permissions', child: Text('الصلاحيات')),
                      PopupMenuItem(
                          value: 'invite', child: Text('دعوة للدخول')),
                      PopupMenuItem(value: 'remove', child: Text('إزالة')),
                    ],
                  ),
                Icon(expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded),
              ],
            ),
          ),
        ),
        if (expanded)
          wallet == null
              ? const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('محفظة العامل غير جاهزة بعد.'),
                )
              : FutureBuilder<List<WalletEntryModel>>(
                  future: _entriesFor(wallet),
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
        const Divider(height: 1),
      ],
    );
  }

  /// Edit a worker's name and phone. A pending worker's phone re-keys freely;
  /// a JOINED worker's phone can also be changed now, but it migrates their
  /// real identity (transactions, notifications, team chat) — confirmed
  /// separately below before saving.
  Future<void> _editWorker(TeamModel team, UserModel w) async {
    final nameC = TextEditingController(text: w.name);
    final phoneC = TextEditingController(text: w.phone ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تعديل بيانات ${w.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameC,
              decoration: const InputDecoration(
                  labelText: 'الاسم', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phoneC,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'رقم الهاتف',
                border: const OutlineInputBorder(),
                helperText: w.joined
                    ? 'العامل انضم بالفعل — تغيير الرقم سينقل بياناته للرقم الجديد'
                    : 'العامل لم ينضم بعد — يمكن تعديله بحرية',
              ),
            ),
            if ((w.email ?? '').isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: Text('البريد: ${w.email}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ')),
        ],
      ),
    );
    final newName = nameC.text.trim();
    final newPhone = phoneC.text.trim();
    nameC.dispose();
    phoneC.dispose();
    if (ok != true || !mounted) return;
    await _db.updateMemberNameLimit(widget.groupId, w.id, name: newName);
    if (newPhone.isNotEmpty && newPhone != (w.phone ?? '')) {
      if (w.joined) {
        final sure = await _confirm(
          'تغيير رقم عامل منضمّ',
          'سيتم نقل كل مصروفات وإشعارات ${w.name} إلى الرقم الجديد. لا يمكن التراجع عن هذا تلقائيًا. متابعة؟',
        );
        if (sure != true || !mounted) return;
        final err = await _db.changeJoinedMemberPhone(widget.groupId, w, newPhone);
        if (err != null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(err)));
        }
      } else {
        final err =
            await _db.changePendingMemberPhone(widget.groupId, w, newPhone);
        if (err != null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(err)));
        }
      }
    }
    if (mounted) await _load();
  }

  /// Access-rights toggle for a worker — same DatabaseService.updateMemberPermissions
  /// family members already get in members_screen.dart. Reports aren't part of
  /// this: a worker's own تقاريري is always scoped to just their own
  /// transactions, so there's nothing privacy-sensitive to gate (the family
  /// member reports toggle was removed for the same reason).
  Future<void> _showWorkerPermissionsDialog(UserModel w) async {
    var canAddExpenses = w.canAddExpenses;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('صلاحيات — ${w.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('تسجيل المصاريف بالصوت/الكتابة'),
                value: canAddExpenses,
                onChanged: (v) => setDialogState(() => canAddExpenses = v),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('حفظ')),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _db.updateMemberPermissions(
        widget.groupId,
        w.id,
        canAddExpenses: canAddExpenses,
      );
      if (mounted) await _load();
    }
  }

  Future<void> _addWorkerDialog(TeamModel team) async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('إضافة عامل إلى ${team.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'اسم العامل',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'رقم موبايل العامل (إلزامي)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'العامل ليس من أفراد العائلة — له محفظة خاصة تموّلها أنت. الرقم إلزامي ليطابقه عند الانضمام.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إضافة')),
        ],
      ),
    );
    final name = nameController.text.trim();
    final phone = phoneController.text.trim();
    nameController.dispose();
    phoneController.dispose();
    if (saved != true) return;
    if (name.isEmpty || phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اكتب اسم العامل ورقم موبايله.')),
        );
      }
      return;
    }
    await _db.addWorker(widget.groupId, team.id, name: name, phone: phone);
    await _load();
  }

  Future<void> _fundWorker(TeamModel team, UserModel worker,
      {required bool withdraw}) async {
    final adminWallets = _wallets.where((w) => w.isAdminWallet).toList();
    if (adminWallets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف محفظة نقدية لك أولًا من الإعدادات.')),
      );
      return;
    }
    WalletModel? workerWallet;
    for (final w in _wallets) {
      if (w.isMemberWallet && w.ownerId == worker.id) {
        workerWallet = w;
        break;
      }
    }
    if (workerWallet == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('محفظة العامل غير جاهزة بعد.')),
      );
      return;
    }
    var source = adminWallets.first;
    final amountController = TextEditingController();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(withdraw ? 'سحب من ${worker.name}' : 'تمويل ${worker.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<WalletModel>(
                initialValue: source,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: withdraw ? 'إلى محفظتي' : 'من محفظتي',
                  border: const OutlineInputBorder(),
                ),
                items: adminWallets
                    .map((w) => DropdownMenuItem(
                        value: w,
                        child: Text(
                            '${w.name} (${_money.format(w.balance)} ج)')))
                    .toList(),
                onChanged: (v) => setDialog(() => source = v ?? source),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'المبلغ', border: OutlineInputBorder()),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                'source': source,
                'amount': double.tryParse(
                    amountController.text.trim().replaceAll(',', '.')),
              }),
              child: Text(withdraw ? 'سحب' : 'تمويل'),
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    if (result == null || !mounted) return;
    final amount = result['amount'] as double?;
    final src = result['source'] as WalletModel;
    if (amount == null || amount <= 0) return;
    final user = context.read<AuthProvider>().user;
    final error = await _db.transferBetweenWallets(
      widget.groupId,
      fromWalletId: withdraw ? workerWallet.id : src.id,
      toWalletId: withdraw ? src.id : workerWallet.id,
      amount: amount,
      byName: user?.name,
      byPhone: user?.phone,
    );
    if (!mounted) return;
    final successMsg = withdraw
        ? 'تم سحب ${_money.format(amount)} ج من ${worker.name}'
        : 'تم تمويل ${worker.name} بـ ${_money.format(amount)} ج';
    if (error == null && user != null) {
      await _db.notifyMultiple(
        widget.groupId,
        title: 'حركة مالية',
        body: successMsg,
        actorId: user.id,
        actorName: user.name,
        targetUserIds: [user.id, worker.id],
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ?? successMsg),
    ));
    await _load();
  }

  Future<void> _removeWorker(TeamModel team, UserModel worker) async {
    final ok = await _confirm(
      'إزالة عامل',
      'إزالة ${worker.name} من فريق ${team.name}؟ سيتم حذف سجله ومحفظته.',
    );
    if (ok != true) return;
    await _db.removeWorker(widget.groupId, team, worker.id);
    await _load();
  }

  Widget _buildTransactionsSection(
    TeamModel team,
    List<TransactionModel> txns,
    bool canManage,
  ) {
    if (txns.isEmpty) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.receipt_long_rounded),
        title: Text('لا توجد مصروفات في هذا الفريق بعد'),
      );
    }
    return Column(
      children: txns.take(20).map((txn) {
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.payments_rounded),
          title: Text('${txn.userName} - ${txn.category}'),
          subtitle: Text(
              '${DateFormat('yyyy/MM/dd - HH:mm').format(txn.date)}${txn.note == null ? '' : '\n${txn.note}'}'),
          isThreeLine: txn.note != null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${_money.format(txn.amount)} ج',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (canManage)
                IconButton(
                  tooltip: 'حذف المصروف',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _deleteTeamTransaction(team, txn),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Future<void> _showTeamDialog({TeamModel? team}) async {
    final owner = context.read<AuthProvider>().user;
    if (owner == null) return;
    final nameController = TextEditingController(text: team?.name ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(team == null ? 'إنشاء فريق' : 'تعديل اسم الفريق'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'اسم الفريق (مثال: العمالة المنزلية)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'الفريق مجموعة عمّال للعائلة. أضف العمّال من زر "إضافة عامل" بعد الإنشاء.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    final name = nameController.text;
    nameController.dispose();
    if (saved != true) return;
    if (team == null) {
      await _db.addTeam(widget.groupId, name: name, owner: owner);
    } else {
      await _db.updateTeam(widget.groupId, team, name: name);
    }
    await _load();
  }

  Future<void> _deleteTeamTransaction(
    TeamModel team,
    TransactionModel txn,
  ) async {
    final ok = await _confirm(
      'حذف مصروف',
      'هل تريد حذف ${_money.format(txn.amount)} ج من فريق ${team.name}؟',
    );
    if (ok != true) return;
    final user = context.read<AuthProvider>().user;
    // deleteTransaction posts the wallet reversal itself (ledger integrity).
    await _db.deleteTransaction(
      widget.groupId,
      txn.id,
      byName: user?.name,
      byPhone: user?.phone,
    );
    if (user != null) {
      await _db.notifyMultiple(
        widget.groupId,
        title: 'حذف مصروف فريق ${team.name}',
        body:
            '${user.name} حذف ${_money.format(txn.amount)} ج - ${txn.category}',
        actorId: user.id,
        actorName: user.name,
        targetUserIds: <String>{team.ownerId, user.id, ...team.memberIds}
            .where((id) => id.isNotEmpty)
            .toList(),
      );
    }
    await _load();
  }

  Future<void> _deleteTeam(TeamModel team) async {
    final ok = await _confirm(
      'حذف الفريق',
      'سيتم حذف فريق ${team.name} ومصروفاته الخاصة. هل أنت متأكد؟',
    );
    if (ok != true) return;
    await _db.deleteTeam(widget.groupId, team.id);
    await _load();
  }

  Future<void> _inviteWorker(TeamModel team, UserModel worker) async {
    final code =
        await _db.createInvite(groupId: widget.groupId, teamId: team.id);
    if (!mounted) return;
    final phoneParam = Uri.encodeComponent(worker.phone ?? '');
    final link =
        '${AppConstants.appWebLink}/install.html?invite=$code&groupId=${widget.groupId}&teamId=${team.id}&phone=$phoneParam&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'دعوة ${worker.name} للانضمام كعامل في فريق ${team.name}.\n\n'
        'افتح الرابط وادخل اسمك للانضمام:\n$link\n\n'
        'رقمك المسجّل: ${worker.phone ?? ''}\n'
        'هذا الرابط للاستخدام مرة واحدة فقط (كود: $code).';
    await Clipboard.setData(ClipboardData(text: message));
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم نسخ دعوة الفريق')),
      );
    }
  }

  Future<bool?> _confirm(String title, String body) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
  }
}
