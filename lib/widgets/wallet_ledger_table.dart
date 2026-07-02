import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../config/theme.dart';
import '../models/wallet_entry_model.dart';

/// The wallet-ledger DataTable (date/statement/in/out/balance/by whom) shared
/// across every screen that shows a wallet's movement — family Settings, the
/// wallets overview screen, and the admin's per-worker team view.
Widget buildWalletLedgerTable(List<WalletEntryModel> entriesOldestFirst) {
  final fmt = NumberFormat('#,##0');
  final entries = entriesOldestFirst.reversed.toList(); // newest first
  if (entries.isEmpty) {
    return const Padding(
      padding: EdgeInsets.all(12),
      child: Text('لا توجد حركات بعد على هذه المحفظة.'),
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
          .map((e) => DataRow(cells: [
                DataCell(Text(dt.format(e.at))),
                DataCell(Text(walletEntryStatement(e))),
                DataCell(Text(
                  e.isDebit ? fmt.format(e.amount) : '—',
                  style: const TextStyle(color: AppTheme.incomeGreen),
                )),
                DataCell(Text(
                  !e.isDebit ? fmt.format(e.amount) : '—',
                  style: const TextStyle(color: AppTheme.expenseRed),
                )),
                DataCell(Text(fmt.format(e.balanceAfter))),
                DataCell(Text(e.byLabel)),
              ]))
          .toList(),
    ),
  );
}

/// The ledger "البيان" (statement) label: the entry's own note if present,
/// else a fallback label derived from its source.
String walletEntryStatement(WalletEntryModel e) {
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
