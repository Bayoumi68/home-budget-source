import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../models/transaction_model.dart';
import '../models/user_model.dart';
import '../models/wallet_model.dart';
import '../models/wallet_entry_model.dart';
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
  String? _memberFilterId; // admin: null = whole family, else a member
  Map<String, List<WalletEntryModel>> _ledger = {}; // walletId → its entries

  @override
  void initState() {
    super.initState();
    _loadMembers();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLedgers());
  }

  Future<void> _loadMembers() async {
    try {
      final members = await _db.getMembersSync(widget.groupId);
      if (mounted) setState(() => _members = members);
    } catch (_) {}
  }

  Future<void> _loadLedgers() async {
    if (!mounted) return;
    final wallets = context.read<BudgetProvider>().wallets;
    final map = <String, List<WalletEntryModel>>{};
    for (final w in wallets) {
      try {
        map[w.id] = await _db.getWalletEntriesSync(widget.groupId, w.id);
      } catch (_) {}
    }
    if (mounted) setState(() => _ledger = map);
  }

  /// Total funded (money in) for the scoped wallets within the period.
  /// A member / single-member view counts every DR (their funding); the whole-
  /// family view counts only external cash in (opening + injection), so internal
  /// admin→member transfers aren't double-counted.
  double _funded(List<WalletModel> scopedWallets, bool memberScope) {
    var total = 0.0;
    for (final w in scopedWallets) {
      for (final e in (_ledger[w.id] ?? const <WalletEntryModel>[])) {
        if (!e.isDebit || !_inPeriod(e.at)) continue;
        if (memberScope || e.source == 'opening' || e.source == 'injection') {
          total += e.amount;
        }
      }
    }
    return total;
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

    // Scope: admin sees the family (or a filtered member); member sees own.
    final effectiveUserId = isAdmin ? _memberFilterId : user?.id;
    final scopedTxns = budget.transactions
        .where((t) => effectiveUserId == null || t.userId == effectiveUserId)
        .where((t) => _inPeriod(t.date))
        .toList();
    // Family reports exclude workers' wallets (workers are reported under الفرق).
    final scopedWallets = budget.wallets
        .where((w) => effectiveUserId == null
            ? !w.isWorkerWallet
            : (w.isMemberWallet && w.ownerId == effectiveUserId))
        .toList();

    final expenses = scopedTxns
        .where((t) => t.isExpense)
        .fold<double>(0, (s, t) => s + t.amount);
    final memberScope = effectiveUserId != null;
    final funded = _funded(scopedWallets, memberScope);
    final walletBalance =
        scopedWallets.fold<double>(0, (s, w) => s + w.balance);

    return Scaffold(
      appBar: AppBar(title: const Text('التقارير')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _topPickers(isAdmin),
          const SizedBox(height: 12),
          _summaryRow(isAdmin, funded, expenses, walletBalance),
          const SizedBox(height: 16),
          _collapsible('توزيع المصروفات', _categorySection(scopedTxns)),
          if (isAdmin)
            _collapsible('أرصدة ومصروفات الأعضاء',
                _byMemberSection(budget.wallets, scopedTxns)),
          if (isAdmin)
            _collapsible(
                'حسب المحفظة', _byWalletSection(budget.wallets, scopedTxns)),
          _collapsible('المصروفات عبر الوقت', _trendSection(scopedTxns)),
          if (isAdmin)
            _collapsible('الميزانيات مقابل الفعلي', _budgetsSection(budget),
                initiallyExpanded: false),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _collapsible(String title, Widget child,
      {bool initiallyExpanded = true}) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 12),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          title: Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [child],
        ),
      ),
    );
  }

  // ─── Top pickers (period + member filter) ───
  Widget _topPickers(bool isAdmin) {
    const periods = {
      'today': 'اليوم',
      'week': 'أسبوع',
      'month': 'هذا الشهر',
      'quarter': '٣ شهور',
      'all': 'الكل',
      'custom': 'مخصص',
    };
    final members = _members.where((m) => !m.isAdmin).toList();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'الفترة',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _period,
                items: periods.entries
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => _onPeriodChanged(v),
              ),
            ),
          ),
        ),
        if (isAdmin) ...[
          const SizedBox(width: 8),
          Expanded(
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'العضو',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  isExpanded: true,
                  value: _memberFilterId,
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('كل العائلة')),
                    ...members.map((m) => DropdownMenuItem<String?>(
                        value: m.id, child: Text(m.name))),
                  ],
                  onChanged: (v) => setState(() => _memberFilterId = v),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _onPeriodChanged(String? v) async {
    if (v == null) return;
    if (v == 'custom') {
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
    } else {
      setState(() => _period = v);
    }
  }

  // ─── Summary ───
  Widget _summaryRow(
      bool isAdmin, double funded, double expenses, double balance) {
    final cards = <Widget>[
      _SummaryCard(
          title: 'إجمالي التمويل',
          amount: funded,
          color: AppTheme.gold,
          icon: Icons.trending_up_rounded,
          money: _money),
      _SummaryCard(
          title: isAdmin ? 'المصروفات' : 'مصروفاتي',
          amount: expenses,
          color: AppTheme.expenseRed,
          icon: Icons.trending_down_rounded,
          money: _money),
      _SummaryCard(
          title: 'الصافي (الرصيد)',
          amount: balance,
          color: AppTheme.incomeGreen,
          icon: Icons.account_balance_wallet_rounded,
          money: _money),
    ];
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
    final members =
        _members.where((m) => !m.isAdmin && !m.isWorker).toList();
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
    final active =
        wallets.where((w) => !w.archived && !w.isWorkerWallet).toList();
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
