import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/constants.dart';
import '../config/theme.dart';
import '../models/family_notification_model.dart';
import '../models/team_model.dart';
import '../models/transaction_model.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../services/database_service.dart';

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
  final Map<String, List<TransactionModel>> _teamTxns = {};

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
      final members = await _db.getMembersSync(widget.groupId);
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
    final byMember = <String, double>{};
    for (final txn in txns.where((t) => t.isExpense)) {
      byMember[txn.userName] = (byMember[txn.userName] ?? 0) + txn.amount;
    }
    final canManage = _canManageTeam(team);

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: ExpansionTile(
        leading: const Icon(Icons.groups_2_rounded),
        title: Text(team.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
            'الرصيد: ${_money.format(team.balance)} ج - إجمالي المصروفات: ${_money.format(spent)} ج'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_balance_wallet_rounded),
            title: Text('رصيد الفريق الحالي: ${_money.format(team.balance)} ج'),
            subtitle: const Text('يمكن زيادة الرصيد من تعديل الفريق'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in byMember.entries)
                  ActionChip(
                    avatar: const Icon(Icons.person_rounded, size: 18),
                    label:
                        Text('${entry.key}: ${_money.format(entry.value)} ج'),
                    onPressed: () => _showMemberTeamDetails(team, entry.key),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _buildMembersSection(team, canManage),
          const Divider(height: 24),
          _buildTransactionsSection(team, txns, canManage),
          if (canManage) ...[
            const Divider(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _showTeamDialog(team: team),
                  icon: const Icon(Icons.edit_rounded),
                  label: const Text('تعديل الفريق'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _shareTeamInvite(team),
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('مشاركة دعوة الفريق'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _deleteTeam(team),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('حذف الفريق'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMembersSection(TeamModel team, bool canManage) {
    final members =
        team.memberIds.map(_memberById).whereType<UserModel>().toList();
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final member in members)
            Chip(
              avatar: const Icon(Icons.person_rounded, size: 18),
              label: Text(member.name),
              deleteIcon: canManage && member.id != team.ownerId
                  ? const Icon(Icons.close_rounded, size: 18)
                  : null,
              onDeleted: canManage && member.id != team.ownerId
                  ? () => _removeMemberFromTeam(team, member)
                  : null,
            ),
        ],
      ),
    );
  }

  UserModel? _memberById(String id) {
    for (final member in _members) {
      if (member.id == id) return member;
    }
    return null;
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
    final auth = context.read<AuthProvider>();
    final owner = auth.user;
    if (owner == null) return;
    final nameController = TextEditingController(text: team?.name ?? '');
    final balanceController = TextEditingController(
        text: team == null || team.balance <= 0
            ? ''
            : team.balance.toStringAsFixed(0));
    final selectedIds = <String>{
      owner.id,
      ...?team?.memberIds,
    };

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(team == null ? 'إنشاء فريق' : 'تعديل الفريق'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'اسم الفريق',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: balanceController,
                  keyboardType: TextInputType.number,
                  textDirection: ui.TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'رصيد الفريق',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                const Align(
                  alignment: Alignment.centerRight,
                  child: Text('الأعضاء',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                ..._members.map(
                  (member) => CheckboxListTile(
                    value: selectedIds.contains(member.id),
                    title: Text(member.name),
                    subtitle: Text(member.phone ?? ''),
                    onChanged: member.id == owner.id
                        ? null
                        : (checked) {
                            setDialogState(() {
                              if (checked == true) {
                                selectedIds.add(member.id);
                              } else {
                                selectedIds.remove(member.id);
                              }
                            });
                          },
                  ),
                ),
              ],
            ),
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
      ),
    );
    nameController.dispose();
    balanceController.dispose();
    if (saved != true) return;

    final selectedMembers =
        _members.where((member) => selectedIds.contains(member.id)).toList();
    final balance = double.tryParse(balanceController.text.trim()) ?? 0;
    if (team == null) {
      await _db.addTeam(
        widget.groupId,
        name: nameController.text,
        owner: owner,
        balance: balance,
        members: selectedMembers,
      );
    } else {
      await _db.updateTeam(
        widget.groupId,
        team,
        name: nameController.text,
        balance: balance,
        members: selectedMembers,
      );
    }
    await _load();
  }

  Future<void> _removeMemberFromTeam(TeamModel team, UserModel member) async {
    final ok = await _confirm(
      'إزالة عضو',
      'هل تريد إزالة ${member.name} من فريق ${team.name}؟',
    );
    if (ok != true) return;
    await _db.removeTeamMember(widget.groupId, team, member.id);
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
    final deleted = await _db.deleteTransaction(widget.groupId, txn.id);
    if (deleted != null) {
      await _db.applyTeamBalanceDelta(widget.groupId, team.id, deleted.amount);
    }
    if (deleted?.walletId != null && deleted!.walletId!.isNotEmpty) {
      await _db.applyWalletDelta(
        widget.groupId,
        deleted.walletId!,
        deleted.amount,
      );
    }
    final user = context.read<AuthProvider>().user;
    if (user != null) {
      await _db.addFamilyNotification(FamilyNotificationModel(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        groupId: widget.groupId,
        title: 'حذف مصروف فريق ${team.name}',
        body:
            '${user.name} حذف ${_money.format(txn.amount)} ج - ${txn.category}',
        actorId: user.id,
        actorName: user.name,
        timestamp: DateTime.now(),
        targetUserIds: <String>{team.ownerId, user.id, ...team.memberIds}
            .where((id) => id.isNotEmpty)
            .toList(),
      ));
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

  Future<void> _showMemberTeamDetails(TeamModel team, String memberName) async {
    final txns = (_teamTxns[team.id] ?? const <TransactionModel>[])
        .where((txn) => txn.userName == memberName)
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('$memberName في ${team.name}',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            for (final txn in txns)
              ListTile(
                leading: const Icon(Icons.receipt_long_rounded),
                title: Text(txn.category),
                subtitle:
                    Text(DateFormat('yyyy/MM/dd - HH:mm').format(txn.date)),
                trailing: Text('${_money.format(txn.amount)} ج'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareTeamInvite(TeamModel team) async {
    final group = await _db.getGroupById(widget.groupId);
    final code = group?.inviteCode.trim() ?? '';
    if (code.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لم أجد كود دعوة العائلة')),
      );
      return;
    }

    final link =
        '${AppConstants.appWebLink}/install.html?invite=$code&groupId=${widget.groupId}&teamId=${team.id}&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'دعوة للانضمام إلى فريق ${team.name} داخل Budget Home.\n\n'
        'افتح الرابط:\n$link\n\n'
        'اكتب رقم تليفونك للدخول.\n'
        'لو التطبيق طلب كود الدعوة استخدم هذا الكود فقط:\n$code\n\n'
        'لو أول مرة تستخدم التطبيق اكتب اسمك أيضًا.\n'
        'بعد الدخول ستجد الفريق في زر "الفرق".\n'
        'رصيد الفريق الحالي: ${team.balance.toStringAsFixed(0)} ج';
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
