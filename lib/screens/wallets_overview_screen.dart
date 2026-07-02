import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../config/theme.dart';
import '../models/wallet_model.dart';
import '../models/wallet_entry_model.dart';
import '../providers/auth_provider.dart';
import '../providers/budget_provider.dart';
import '../services/database_service.dart';
import '../utils/money_format.dart';

/// Opened from the chat header's "رصيد المحافظ" total. Lists every wallet the
/// user may see (admin: cash sources ONLY — a family member's or worker's
/// wallet is their own asset, not the admin's, and is monitored instead via
/// that member's/team's own detail screen; member: only their own), each line
/// tappable to expand/collapse its ledger movement.
class WalletsOverviewScreen extends StatefulWidget {
  final String groupId;
  const WalletsOverviewScreen({super.key, required this.groupId});

  @override
  State<WalletsOverviewScreen> createState() => _WalletsOverviewScreenState();
}

class _WalletsOverviewScreenState extends State<WalletsOverviewScreen> {
  final _db = DatabaseService();
  final Set<String> _expanded = {};
  // Cache each wallet's ledger future so rebuilds don't refetch; the key folds
  // in the balance so it reloads only when that wallet actually changed.
  final Map<String, Future<List<WalletEntryModel>>> _entryFutures = {};

  Future<List<WalletEntryModel>> _entriesFor(WalletModel w) {
    final key = '${w.id}|${w.updatedAt?.toIso8601String() ?? ''}|${w.balance}';
    return _entryFutures.putIfAbsent(
        key, () => _db.getWalletEntriesSync(widget.groupId, w.id));
  }

  /// Self-heal on every pull-to-refresh: fold in any expense a wallet ledger
  /// proves happened but whose transaction record never got saved. Admin
  /// reconciles everyone at once; a member reconciles just their own wallet.
  Future<void> _onRefresh(BudgetProvider budget) async {
    final user = context.read<AuthProvider>().user;
    if (user == null) return;
    if (user.isAdmin) {
      await _db.reconcileAllMemberWallets(widget.groupId);
    } else {
      for (final w in budget.wallets) {
        if (w.isMemberWallet && w.ownerId == user.id) {
          await _db.reconcileMemberWallet(widget.groupId, user, w);
        }
      }
    }
    await budget.refreshData(widget.groupId);
  }

  @override
  Widget build(BuildContext context) {
    final budget = context.watch<BudgetProvider>();
    final user = context.watch<AuthProvider>().user;
    final isAdmin = user?.isAdmin == true;

    final wallets = (isAdmin
            ? budget.wallets.where((w) => w.isAdminWallet)
            : budget.wallets
                .where((w) => w.isMemberWallet && w.ownerId == user?.id))
        .toList()
      ..sort((a, b) {
        if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
        if (a.isAdminWallet != b.isAdminWallet) return a.isAdminWallet ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    final total = wallets.fold<double>(0, (s, w) => s + w.balance);

    return Scaffold(
      appBar: AppBar(title: const Text('المحافظ والأرصدة')),
      body: budget.loading && wallets.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _onRefresh(budget),
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _totalCard(total),
                  const SizedBox(height: 12),
                  if (wallets.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('لا توجد محافظ بعد.')),
                    )
                  else
                    ...wallets.map(_walletCard),
                ],
              ),
            ),
    );
  }

  Widget _totalCard(double total) => Card(
        color: AppTheme.primaryDark,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          child: Column(
            children: [
              const Text('إجمالي الرصيد',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 6),
              Text('${formatMoney(total)} ج',
                  style: const TextStyle(
                      color: AppTheme.incomeGreen,
                      fontSize: 26,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );

  Widget _walletCard(WalletModel w) {
    final expanded = _expanded.contains(w.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(w.id);
              } else {
                _expanded.add(w.id);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Icon(
                    w.isMemberWallet
                        ? Icons.person_rounded
                        : (w.isDefault
                            ? Icons.account_balance_wallet_rounded
                            : Icons.wallet_rounded),
                    color: AppTheme.gold,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(w.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(
                          'الرصيد: ${formatMoney(w.balance)} ج'
                          '${w.description.isEmpty ? '' : ' — ${w.description}'}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Icon(expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            _ledger(w),
          ],
        ],
      ),
    );
  }

  Widget _ledger(WalletModel w) {
    return FutureBuilder<List<WalletEntryModel>>(
      future: _entriesFor(w),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        final entries =
            (snap.data ?? const <WalletEntryModel>[]).reversed.toList();
        if (entries.isEmpty) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('لا توجد حركات بعد على هذه المحفظة.'),
            ),
          );
        }
        final dt = DateFormat('yyyy/MM/dd HH:mm');
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 18,
            headingRowHeight: 34,
            dataRowMinHeight: 36,
            dataRowMaxHeight: 56,
            columns: const [
              DataColumn(label: Text('التاريخ')),
              DataColumn(label: Text('البيان')),
              DataColumn(label: Text('وارد')),
              DataColumn(label: Text('منصرف')),
              DataColumn(label: Text('الرصيد')),
              DataColumn(label: Text('بواسطة')),
            ],
            rows: entries
                .map(
                  (e) => DataRow(cells: [
                    DataCell(Text(dt.format(e.at))),
                    DataCell(Text(_statement(e))),
                    DataCell(Text(
                      e.isDebit ? formatMoney(e.amount) : '—',
                      style: const TextStyle(color: AppTheme.incomeGreen),
                    )),
                    DataCell(Text(
                      !e.isDebit ? formatMoney(e.amount) : '—',
                      style: const TextStyle(color: AppTheme.expenseRed),
                    )),
                    DataCell(Text(formatMoney(e.balanceAfter))),
                    DataCell(Text(e.byLabel)),
                  ]),
                )
                .toList(),
          ),
        );
      },
    );
  }

  String _statement(WalletEntryModel e) {
    final note = (e.note ?? '').trim();
    if (note.isNotEmpty) return note;
    switch (e.source) {
      case 'opening':
        return 'رصيد افتتاحي';
      case 'injection':
        return 'إيداع نقدي';
      case 'withdrawal':
        return 'سحب نقدي';
      case 'expense':
        return 'مصروف';
      case 'adjustment':
        return 'تعديل رصيد';
      case 'reversal':
        return 'إرجاع';
      case 'transfer':
        return 'تحويل';
      default:
        return e.source;
    }
  }
}
