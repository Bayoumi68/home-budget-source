import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../models/team_model.dart';
import '../models/transaction_model.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';

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
  final _controller = TextEditingController();
  final _money = NumberFormat('#,###');
  TeamModel? _team;
  List<TransactionModel> _txns = const [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final team = await _db.getTeamById(widget.groupId, widget.teamId);
    final myId = context.read<AuthProvider>().user?.id;
    final all = team == null
        ? const <TransactionModel>[]
        : await _db.getTeamTransactions(widget.groupId, widget.teamId);
    // A worker sees only their OWN expenses, not the whole team's.
    final txns =
        myId == null ? all : all.where((t) => t.userId == myId).toList();
    if (!mounted) return;
    setState(() {
      _team = team;
      _txns = txns;
      _loading = false;
    });
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    final team = _team;
    if (text.isEmpty || user == null || team == null || _saving) return;

    final parsed = AIService.parseExpenseMessages(text)
        .where((item) => item['isExpense'] == true)
        .toList();
    if (parsed.isEmpty) {
      _snack('اكتب مصروف واضح مثل: دفعت 100 بنزين');
      return;
    }
    final total =
        parsed.fold<double>(0, (sum, item) => sum + (item['amount'] as double));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد مصروف الفريق'),
        content: Text(
          'سيتم تسجيل ${parsed.length} مصروف داخل فريق ${team.name} بإجمالي ${total.toStringAsFixed(0)} ج.\nلن يظهر هذا كمصروف عائلي عام.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تعديل'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('تسجيل'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);
    try {
      final warning = await context.read<ChatProvider>().sendTeamExpenseText(
            widget.groupId,
            user,
            text,
            team,
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;
    final team = _team;
    return Scaffold(
      appBar: AppBar(
        title: Text(team == null ? 'فريق' : team.name),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
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
                                        '${txn.category} - ${_money.format(txn.amount)} ج'),
                                    subtitle: Text(
                                      '${txn.userName}\n${DateFormat('yyyy/MM/dd - HH:mm').format(txn.date)}',
                                    ),
                                    isThreeLine: true,
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
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                minLines: 1,
                                maxLines: 3,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _submit(),
                                decoration: const InputDecoration(
                                  hintText: 'اكتب مصروف الفريق',
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
