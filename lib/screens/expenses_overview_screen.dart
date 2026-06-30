import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../config/theme.dart';
import '../models/transaction_model.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../providers/budget_provider.dart';
import '../services/database_service.dart';

/// Opened from the chat header's "مصروفات العائلة" total. Lists each member
/// with their spending this month, each line tappable to expand/collapse the
/// member's own expense movements. A member sees only themselves.
class ExpensesOverviewScreen extends StatefulWidget {
  final String groupId;
  const ExpensesOverviewScreen({super.key, required this.groupId});

  @override
  State<ExpensesOverviewScreen> createState() => _ExpensesOverviewScreenState();
}

class _ExpensesOverviewScreenState extends State<ExpensesOverviewScreen> {
  final _db = DatabaseService();
  final Set<String> _expanded = {};
  List<UserModel> _members = [];
  bool _loadingMembers = true;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final m = await _db.getFamilyMembersSync(widget.groupId);
      if (mounted) {
        setState(() {
          _members = m;
          _loadingMembers = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMembers = false);
    }
  }

  bool _thisMonth(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month;
  }

  @override
  Widget build(BuildContext context) {
    final budget = context.watch<BudgetProvider>();
    final user = context.watch<AuthProvider>().user;
    final isAdmin = user?.isAdmin == true;
    final fmt = NumberFormat('#,##0');

    final monthExpenses = budget.transactions
        .where((t) => t.isExpense && _thisMonth(t.date))
        .toList();
    final byUser = <String, List<TransactionModel>>{};
    for (final t in monthExpenses) {
      byUser.putIfAbsent(t.userId, () => []).add(t);
    }

    final rows = <_MemberExpenses>[];
    if (isAdmin) {
      final seen = <String>{};
      for (final m in _members) {
        rows.add(_MemberExpenses(m.id, m.name, byUser[m.id] ?? const []));
        seen.add(m.id);
      }
      // Spending by ids no longer in the member list (e.g. removed members) so
      // the per-member totals still reconcile with the family total.
      for (final entry in byUser.entries) {
        if (seen.contains(entry.key)) continue;
        final name = entry.value.isNotEmpty ? entry.value.first.userName : '';
        rows.add(_MemberExpenses(
            entry.key, name.isEmpty ? 'غير معروف' : name, entry.value));
      }
    } else if (user != null) {
      rows.add(_MemberExpenses(user.id, user.name, byUser[user.id] ?? const []));
    }
    rows.sort((a, b) => b.total.compareTo(a.total));

    final total = isAdmin
        ? monthExpenses.fold<double>(0, (s, t) => s + t.amount)
        : (byUser[user?.id]?.fold<double>(0, (s, t) => s + t.amount) ?? 0);

    return Scaffold(
      appBar: AppBar(title: Text(isAdmin ? 'مصروفات العائلة' : 'مصروفاتي')),
      body: (_loadingMembers && isAdmin)
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await budget.refreshData(widget.groupId);
                await _loadMembers();
              },
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _totalCard(total, fmt),
                  const SizedBox(height: 12),
                  if (total == 0)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('لا توجد مصاريف هذا الشهر.')),
                    )
                  else
                    ...rows.map((r) => _memberCard(r, fmt)),
                ],
              ),
            ),
    );
  }

  Widget _totalCard(double total, NumberFormat fmt) => Card(
        color: AppTheme.primaryDark,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          child: Column(
            children: [
              const Text('إجمالي مصروفات هذا الشهر',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 6),
              Text('${fmt.format(total)} ج',
                  style: const TextStyle(
                      color: AppTheme.expenseRed,
                      fontSize: 26,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );

  Widget _memberCard(_MemberExpenses r, NumberFormat fmt) {
    final expanded = _expanded.contains(r.id);
    final txns = [...r.txns]..sort((a, b) => b.date.compareTo(a.date));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(r.id);
              } else {
                _expanded.add(r.id);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  const Icon(Icons.person_rounded, color: AppTheme.gold),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.name.isEmpty ? 'بدون اسم' : r.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text('${txns.length} حركة',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                  Text('${fmt.format(r.total)} ج',
                      style: const TextStyle(
                          color: AppTheme.expenseRed,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Icon(expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            if (txns.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text('لا توجد مصاريف لهذا العضو هذا الشهر.'),
                ),
              )
            else
              ...txns.map((t) => _txnLine(t, fmt)),
          ],
        ],
      ),
    );
  }

  Widget _txnLine(TransactionModel t, NumberFormat fmt) {
    final dt = DateFormat('yyyy/MM/dd');
    final note = (t.note ?? '').trim();
    final cat = t.category.trim().isEmpty ? 'أخرى' : t.category.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(cat, style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(
                  '${dt.format(t.date)}${note.isEmpty ? '' : ' — $note'}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          Text('${fmt.format(t.amount)} ج',
              style: const TextStyle(
                  color: AppTheme.expenseRed, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _MemberExpenses {
  final String id;
  final String name;
  final List<TransactionModel> txns;
  _MemberExpenses(this.id, this.name, this.txns);
  double get total => txns.fold<double>(0, (s, t) => s + t.amount);
}
