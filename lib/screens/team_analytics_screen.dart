import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../models/category_model.dart';
import '../models/transaction_model.dart';
import '../models/wallet_model.dart';
import '../providers/auth_provider.dart';
import '../services/database_service.dart';
import '../utils/money_format.dart';
import '../utils/period_utils.dart';

/// My own team report — same page shape as a regular (non-admin) family
/// member's التقارير screen: period picker, category breakdown, trend chart.
/// No cross-member visibility: the team channel stays as scoped to "me only"
/// as the family channel is for a plain member — that oversight belongs to
/// the admin's existing per-worker ledger view in teams_screen.dart, not to
/// a peer worker.
class TeamAnalyticsScreen extends StatefulWidget {
  final String groupId;
  final String teamId;
  final String teamName;

  const TeamAnalyticsScreen({
    super.key,
    required this.groupId,
    required this.teamId,
    required this.teamName,
  });

  @override
  State<TeamAnalyticsScreen> createState() => _TeamAnalyticsScreenState();
}

class _TeamAnalyticsScreenState extends State<TeamAnalyticsScreen> {
  final _db = DatabaseService();
  // Default to full history, matching the wallet ledger card (which is never
  // period-filtered) — a 'month' default silently hid real data with no
  // indicator why, reading as a bug.
  String _period = 'all';
  DateTimeRange? _customRange;

  bool _loading = true;
  List<TransactionModel> _myTxns = const [];
  WalletModel? _wallet;
  List<CategoryModel> _categories = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final me = context.read<AuthProvider>().user;
    final myId = me?.id;
    final wallets = await _db.getWalletsSync(widget.groupId);
    WalletModel? myWallet;
    for (final w in wallets) {
      if (w.isMemberWallet && w.ownerId == myId) {
        myWallet = w;
        break;
      }
    }
    // Self-heal on every refresh — same reasoning as team_member_home_screen:
    // a wallet-ledger entry proves an expense happened even if its
    // transaction record never got saved or drifted from an old id/team.
    if (me != null && myWallet != null) {
      await _db.reconcileMemberWallet(widget.groupId, me, myWallet);
    }
    final results = await Future.wait([
      _db.getTeamTransactions(widget.groupId, widget.teamId),
      _db.getCategoriesSync(widget.groupId),
    ]);
    if (!mounted) return;
    final allTxns = results[0] as List<TransactionModel>;
    setState(() {
      _myTxns = myId == null
          ? const []
          : allTxns.where((t) => t.userId == myId).toList();
      _wallet = myWallet;
      _categories = results[1] as List<CategoryModel>;
      _loading = false;
    });
  }

  DateTime get _start => PeriodUtils.start(_period, _customRange);
  DateTime get _end => PeriodUtils.end(_period, _customRange);
  bool _inPeriod(DateTime d) => PeriodUtils.inPeriod(d, _period, _customRange);

  @override
  Widget build(BuildContext context) {
    final scopedTxns = _myTxns.where((t) => _inPeriod(t.date)).toList();
    final expenses = scopedTxns
        .where((t) => t.isExpense)
        .fold<double>(0, (s, t) => s + t.amount);
    final balance = _wallet?.balance ?? 0;

    return Scaffold(
      appBar: AppBar(title: Text('تقاريري — ${widget.teamName}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _periodPicker(),
                  const SizedBox(height: 12),
                  _summaryRow(expenses, balance),
                  const SizedBox(height: 16),
                  _collapsible('توزيع مصروفاتي', _categorySection(scopedTxns)),
                  _collapsible('مصروفاتي عبر الوقت', _trendSection(scopedTxns)),
                  const SizedBox(height: 32),
                ],
              ),
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

  // ─── Period picker ───
  Widget _periodPicker() {
    const periods = PeriodUtils.labels;
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'الفترة',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _period,
          items: periods.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (v) => _onPeriodChanged(v),
        ),
      ),
    );
  }

  Future<void> _onPeriodChanged(String? v) async {
    final r = await PeriodUtils.pickPeriod(context, v, _customRange);
    if (r == null || !mounted) return;
    setState(() {
      _period = r.period;
      _customRange = r.range;
    });
  }

  // ─── Summary ───
  Widget _summaryRow(double expenses, double balance) {
    final cards = <Widget>[
      _SummaryCard(
          title: 'مصروفاتي',
          amount: expenses,
          color: AppTheme.expenseRed,
          icon: Icons.trending_down_rounded),
      _SummaryCard(
          title: 'رصيدي الحالي',
          amount: balance,
          color: AppTheme.incomeGreen,
          icon: Icons.account_balance_wallet_rounded),
    ];
    return Row(
      children: cards
          .map((c) => Expanded(
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: c)))
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
              leading: Text(_categories.iconFor(e.key),
                  style: const TextStyle(fontSize: 22)),
              title: Text(e.key),
              subtitle: LinearProgressIndicator(
                value: total > 0 ? e.value / total : 0,
                color: AppTheme.accentTeal,
                backgroundColor: Colors.grey.shade200,
              ),
              trailing: Text('${formatMoney(e.value)} ج\n${pct.toStringAsFixed(0)}%',
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
    final maxVal = buckets.values.fold<double>(0, (a, b) => a > b ? a : b);
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
                  child: Text(order[i], style: const TextStyle(fontSize: 9)),
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
  const _SummaryCard(
      {required this.title,
      required this.amount,
      required this.color,
      required this.icon});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 6),
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text('${formatMoney(amount)} ج',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        ]),
      ),
    );
  }
}
