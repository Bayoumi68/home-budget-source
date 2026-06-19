import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../providers/budget_provider.dart';

class AnalyticsScreen extends StatefulWidget {
  final String groupId;
  const AnalyticsScreen({super.key, required this.groupId});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  @override
  Widget build(BuildContext context) {
    final budget = context.watch<BudgetProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('تقارير الشهر الحالي')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _SummaryCard(title: 'المصروفات', amount: budget.totalExpenses, color: AppTheme.expenseRed, icon: Icons.trending_down_rounded),
                const SizedBox(width: 12),
                _SummaryCard(title: 'الدخل', amount: budget.totalIncome, color: AppTheme.incomeGreen, icon: Icons.trending_up_rounded),
                const SizedBox(width: 12),
                _SummaryCard(title: 'المتبقي', amount: budget.balance, color: AppTheme.gold, icon: Icons.account_balance_wallet_rounded),
              ],
            ),
            const SizedBox(height: 24),
            const Text('توزيع المصروفات — الشهر الحالي', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(height: 250, child: _buildPieChart(budget.categoryTotals)),
            const SizedBox(height: 16),
            ...budget.categoryTotals.entries.map((entry) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Text(AppConstants.categoryIcons[entry.key] ?? '📌', style: const TextStyle(fontSize: 24)),
                title: Text(entry.key),
                trailing: Text('${NumberFormat('#,###').format(entry.value)} ج',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.expenseRed)),
              ),
            )),
            if (budget.categoryTotals.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('لا توجد مصروفات بعد', style: TextStyle(color: Colors.grey, fontSize: 16))),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPieChart(Map<String, double> data) {
    if (data.isEmpty) return const Center(child: Text('لا توجد بيانات', style: TextStyle(color: Colors.grey)));
    final total = data.values.fold(0.0, (a, b) => a + b);
    final colors = [AppTheme.expenseRed, Colors.blue, Colors.orange, Colors.purple, Colors.teal, Colors.pink, Colors.indigo, Colors.brown, Colors.cyan, Colors.amber, Colors.deepOrange, Colors.lime, Colors.deepPurple, Colors.grey];

    return PieChart(PieChartData(
      sections: data.entries.toList().asMap().entries.map((entry) {
        final idx = entry.key;
        final e = entry.value;
        final percentage = (e.value / total) * 100;
        return PieChartSectionData(
          value: e.value,
          title: '${percentage.toStringAsFixed(1)}%',
          color: colors[idx % colors.length],
          radius: 60,
          titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
        );
      }).toList(),
      centerSpaceRadius: 40,
      sectionsSpace: 2,
    ));
  }
}

class _SummaryCard extends StatelessWidget {
  final String title; final double amount; final Color color; final IconData icon;
  const _SummaryCard({required this.title, required this.amount, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Expanded(child: Card(child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text('${NumberFormat('#,###').format(amount)} ج',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
      ]),
    )));
  }
}
