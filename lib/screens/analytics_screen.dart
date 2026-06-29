import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../models/transaction_model.dart';
import '../models/user_model.dart';
import '../models/wallet_model.dart';
import '../providers/auth_provider.dart';
import '../providers/budget_provider.dart';
import '../services/database_service.dart';

class AnalyticsScreen extends StatefulWidget {
  final String groupId;
  const AnalyticsScreen({super.key, required this.groupId});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  final _db = DatabaseService();
  final _money = NumberFormat('#,###');
  String _period = 'month';
  DateTimeRange? _customRange;
  List<UserModel> _members = [];

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final members = await _db.getMembersSync(widget.groupId);
      if (mounted) setState(() => _members = members);
    } catch (_) {}
  }

  DateTime get _start {
    final now = DateTime.now();
    switch (_period) {
      case 'today':
        return DateTime(now.year, now.month, now.day);
      case 'week':
        return DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 6));
      case 'month':
        return DateTime(now.year, now.month, 1);
      case 'quarter':
        return DateTime(now.year, now.month - 2, 1);
      case 'all':
        return DateTime(2000);
      case 'custom':
        final r = _customRange;
        return r == null ? DateTime(2000) : r.start;
      default:
        return DateTime(now.year, now.month, 1);
    }
  }

  DateTime get _end {
    if (_period == 'custom' && _customRange != null) {
      final e = _customRange!.end;
      return DateTime(e.year, e.month, e.day, 23, 59, 59);
    }
    return DateTime.now();
  }

  bool _inPeriod(DateTime d) => !d.isBefore(_start) && !d.isAfter(_end);

  @override
  Widget build(BuildContext context) {
    final budget = context.watch<BudgetProvider>();
    final user = context.read<AuthProvider>().user;
    final isAdmin = user?.isAdmin == true;

    // Scope: admin sees the whole family; a member sees only their own data.
    final scopedTxns = budget.transactions
        .where((t) => isAdmin || t.userId == user?.id)
        .where((t) => _inPeriod(t.date))
        .toList();
    final scopedWallets = budget.wallets
        .where((w) => isAdmin || (w.isMemberWallet && w.ownerId == user?.id))
        .toList();

    final expenses = scopedTxns
        .where((t) => t.isExpense)
        .fold<double>(0, (s, t) => s + t.amount);
    final income = scopedTxns
        .where((t) => !t.isExpense)
        .fold<double>(0, (s, t) => s + t.amount);
    final walletBalance =
        scopedWallets.fold<double>(0, (s, w) => s + w.balance);

    return Scaffold(
      appBar: AppBar(title: const Text('التقارير')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _periodSelector(),
          const SizedBox(height: 16),
          _summaryRow(isAdmin, expenses, income, walletBalance),
          const SizedBox(height: 24),
          _sectionTitle('توزيع المصروفات'),
          const SizedBox(height: 8),
          _categorySection(scopedTxns),
          if (isAdmin) ...[
            const SizedBox(height: 24),
            _sectionTitle('أرصدة ومصروفات الأعضاء'),
            const SizedBox(height: 8),
            _byMemberSection(budget.wallets, scopedTxns),
          ],
          if (isAdmin) ...[
            const SizedBox(height: 24),
            _sectionTitle('حسب المحفظة'),
            const SizedBox(height: 8),
            _byWalletSection(budget.wallets, scopedTxns),
          ],
          const SizedBox(height: 24),
          _sectionTitle('المصروفات عبر الوقت'),
          const SizedBox(height: 8),
          _trendSection(scopedTxns),
          if (isAdmin) ...[
            const SizedBox(height: 24),
            _sectionTitle('الميزانيات مقابل الفعلي'),
            const SizedBox(height: 8),
            _budgetsSection(budget),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) =>
      Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold));

  // ─── Period selector ───
  Widget _periodSelector() {
    const options = {
      'today': 'اليوم',
      'week': 'أسبوع',
      'month': 'هذا الشهر',
      'quarter': '٣ شهور',
      'all': 'الكل',
    };
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        ...options.entries.map(
          (e) => ChoiceChip(
            label: Text(e.value),
            selected: _period == e.key,
            onSelected: (_) => setState(() => _period = e.key),
          ),
        ),
        ChoiceChip(
          avatar: const Icon(Icons.date_range_rounded, size: 16),
          label: Text(_period == 'custom' && _customRange != null
              ? '${DateFormat('MM/dd').format(_customRange!.start)} - ${DateFormat('MM/dd').format(_customRange!.end)}'
              : 'مخصص'),
          selected: _period == 'custom',
          onSelected: (_) async {
            final now = DateTime.now();
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: now,
              initialDateRange: _customRange ??
                  DateTimeRange(
                      start: now.subtract(const Duration(days: 7)), end: now),
            );
            if (picked != null) {
              setState(() {
                _customRange = picked;
                _period = 'custom';
              });
            }
          },
        ),
      ],
    );
  }

  // ─── Summary ───
  Widget _summaryRow(
      bool isAdmin, double expenses, double income, double balance) {
    final cards = <Widget>[
      _SummaryCard(
          title: 'المصروفات',
          amount: expenses,
          color: AppTheme.expenseRed,
          icon: Icons.trending_down_rounded,
          money: _money),
      _SummaryCard(
          title: isAdmin ? 'رصيد المحافظ' : 'رصيد محفظتي',
          amount: balance,
          color: AppTheme.incomeGreen,
          icon: Icons.account_balance_wallet_rounded,
          money: _money),
    ];
    if (isAdmin) {
      cards.add(_SummaryCard(
          title: 'الدخل',
          amount: income,
          color: AppTheme.gold,
          icon: Icons.trending_up_rounded,
          money: _money));
      cards.add(_SummaryCard(
          title: 'الصافي',
          amount: income - expenses,
          color: AppTheme.accentTeal,
          icon: Icons.savings_rounded,
          money: _money));
    }
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: cards
          .map((c) => SizedBox(
              width: (MediaQuery.of(context).size.width - 32 - 12) / 2, child: c))
          .toList(),
    );
  }

  // ─── By category ───
  Widget _categorySection(List<TransactionModel> txns) {
    final byCat = <String, double>{};
    for (final t in txns.where((t) => t.isExpense)) {
      final c = t.category.isEmpty ? 'أخرى' : t.category;
      byCat[c] = (byCat[c] ?? 0) + t.amount;
    }
    if (byCat.isEmpty) return _empty('لا توجد مصروفات في هذه الفترة');
    final sorted = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = byCat.values.fold<double>(0, (a, b) => a + b);
    return Column(
      children: [
        SizedBox(height: 220, child: _pie(sorted, total)),
        const SizedBox(height: 12),
        ...sorted.map((e) {
          final pct = total > 0 ? (e.value / total * 100) : 0;
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              leading: Text(AppConstants.categoryIcons[e.key] ?? '📌',
                  style: const TextStyle(fontSize: 22)),
              title: Text(e.key),
              subtitle: LinearProgressIndicator(
                value: total > 0 ? e.value / total : 0,
                color: AppTheme.accentTeal,
                backgroundColor: Colors.grey.shade200,
              ),
              trailing: Text('${_money.format(e.value)} ج\n${pct.toStringAsFixed(0)}%',
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: AppTheme.expenseRed)),
            ),
          );
        }),
      ],
    );
  }

  Widget _pie(List<MapEntry<String, double>> data, double total) {
    final colors = [
      AppTheme.expenseRed,
      Colors.blue,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.brown,
      Colors.cyan,
      Colors.amber,
      Colors.deepOrange,
      Colors.lime,
      Colors.deepPurple,
      Colors.grey,
    ];
    return PieChart(PieChartData(
      sections: data.asMap().entries.map((entry) {
        final idx = entry.key;
        final e = entry.value;
        final pct = total > 0 ? (e.value / total * 100) : 0;
        return PieChartSectionData(
          value: e.value,
          title: '${pct.toStringAsFixed(0)}%',
          color: colors[idx % colors.length],
          radius: 56,
          titleStyle: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
        );
      }).toList(),
      centerSpaceRadius: 38,
      sectionsSpace: 2,
    ));
  }

  // ─── By member (admin) ───
  Widget _byMemberSection(
      List<WalletModel> wallets, List<TransactionModel> txns) {
    final spentByUser = <String, double>{};
    for (final t in txns.where((t) => t.isExpense)) {
      spentByUser[t.userId] = (spentByUser[t.userId] ?? 0) + t.amount;
    }
    final members = _members.where((m) => !m.isAdmin).toList();
    if (members.isEmpty) return _empty('لا يوجد أعضاء');
    return Column(
      children: members.map((m) {
        WalletModel? w;
        for (final x in wallets) {
          if (x.isMemberWallet && x.ownerId == m.id) {
            w = x;
            break;
          }
        }
        final balance = w?.balance ?? 0;
        final spent = spentByUser[m.id] ?? 0;
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.person_rounded, color: AppTheme.gold),
            title: Text(m.name),
            subtitle: Text('صرف: ${_money.format(spent)} ج'),
            trailing: Text('الرصيد\n${_money.format(balance)} ج',
                textAlign: TextAlign.end,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: balance > 0
                        ? AppTheme.incomeGreen
                        : Colors.grey)),
          ),
        );
      }).toList(),
    );
  }

  // ─── By wallet (admin) ───
  Widget _byWalletSection(
      List<WalletModel> wallets, List<TransactionModel> txns) {
    final spentByWallet = <String, double>{};
    for (final t in txns.where((t) => t.isExpense && t.walletId != null)) {
      spentByWallet[t.walletId!] = (spentByWallet[t.walletId!] ?? 0) + t.amount;
    }
    final active = wallets.where((w) => !w.archived).toList();
    if (active.isEmpty) return _empty('لا توجد محافظ');
    return Column(
      children: active.map((w) {
        final spent = spentByWallet[w.id] ?? 0;
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            leading: Icon(
                w.isMemberWallet
                    ? Icons.person_rounded
                    : Icons.account_balance_wallet_rounded,
                color: AppTheme.accentTeal),
            title: Text(w.name),
            subtitle: Text(w.isMemberWallet ? 'محفظة عضو' : 'مصدر نقدي'),
            trailing: Text(
                'صرف ${_money.format(spent)} ج\nرصيد ${_money.format(w.balance)} ج',
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        );
      }).toList(),
    );
  }

  // ─── Trend over time ───
  Widget _trendSection(List<TransactionModel> txns) {
    final expenses = txns.where((t) => t.isExpense).toList();
    if (expenses.isEmpty) return _empty('لا توجد بيانات');
    final spanDays = _end.difference(_start).inDays;
    final byMonth = spanDays > 62;
    final buckets = <String, double>{};
    final order = <String>[];
    for (final t in expenses) {
      final key = byMonth
          ? DateFormat('yyyy/MM').format(t.date)
          : DateFormat('MM/dd').format(t.date);
      if (!buckets.containsKey(key)) order.add(key);
      buckets[key] = (buckets[key] ?? 0) + t.amount;
    }
    order.sort();
    final maxVal =
        buckets.values.fold<double>(0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 200,
      child: BarChart(BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxVal * 1.2,
        barTouchData: BarTouchData(enabled: true),
        titlesData: FlTitlesData(
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= order.length) return const SizedBox();
                if (order.length > 8 && i % 2 != 0) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(order[i],
                      style: const TextStyle(fontSize: 9)),
                );
              },
            ),
          ),
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        barGroups: order.asMap().entries.map((e) {
          return BarChartGroupData(x: e.key, barRods: [
            BarChartRodData(
              toY: buckets[e.value] ?? 0,
              color: AppTheme.accentTeal,
              width: order.length > 12 ? 8 : 16,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          ]);
        }).toList(),
      )),
    );
  }

  // ─── Budgets vs actual (admin) ───
  Widget _budgetsSection(BudgetProvider budget) {
    final budgets = budget.budgets.where((b) => b.limit > 0).toList();
    if (budgets.isEmpty) return _empty('لا توجد حدود ميزانية محددة');
    return Column(
      children: budgets.map((b) {
        final spent = b.spent;
        final pct = b.limit > 0 ? (spent / b.limit).clamp(0.0, 1.0) : 0.0;
        final remaining = b.limit - spent;
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${AppConstants.categoryIcons[b.category] ?? '📌'} ${b.category}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(
                      remaining >= 0
                          ? 'متبقي ${_money.format(remaining)} ج'
                          : 'تجاوز ${_money.format(-remaining)} ج',
                      style: TextStyle(
                          color: remaining >= 0
                              ? AppTheme.incomeGreen
                              : AppTheme.expenseRed,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: pct.toDouble(),
                  minHeight: 6,
                  color: pct > .85 ? AppTheme.expenseRed : AppTheme.accentTeal,
                  backgroundColor: Colors.grey.shade200,
                ),
                const SizedBox(height: 4),
                Text(
                    'حد ${b.periodLabel} ${_money.format(b.limit)} ج — صرف ${_money.format(spent)} ج',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _empty(String t) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
            child: Text(t, style: const TextStyle(color: Colors.grey))),
      );
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final double amount;
  final Color color;
  final IconData icon;
  final NumberFormat money;
  const _SummaryCard(
      {required this.title,
      required this.amount,
      required this.color,
      required this.icon,
      required this.money});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 6),
          Text(title,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text('${money.format(amount)} ج',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        ]),
      ),
    );
  }
}
