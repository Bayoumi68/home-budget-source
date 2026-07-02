import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/category_model.dart';
import '../models/resolved_expense.dart';
import '../utils/money_format.dart';

/// One category-picker UI, reused by both the long-press "تغيير النوع" flow
/// and the mandatory pre-send confirm dialog below — shared across the main
/// chat screen and the team-member screen so there's a single picker, not two.
Future<CategoryModel?> pickCategory(
  BuildContext context,
  Iterable<CategoryModel> categories, {
  String title = 'اختر النوع الصحيح',
}) {
  return showDialog<CategoryModel>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        for (final c in categories)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, c),
            child: Text('${c.icon}  ${c.name}'),
          ),
      ],
    ),
  );
}

/// Mandatory confirm-before-save step for EVERY expense/income (not just
/// multi-item messages): shows the FINAL resolved category for each item
/// (post hard-match, identical to what will actually be saved) with a
/// "تغيير النوع" chip to change it before confirming. Returns the
/// (possibly-edited) list, or null if the user cancelled.
Future<List<ResolvedExpense>?> confirmResolvedExpenses(
  BuildContext context,
  List<ResolvedExpense> items,
  List<CategoryModel> allCategories,
) async {
  var draft = List<ResolvedExpense>.from(items);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final total = draft
            .where((r) => r.isExpense)
            .fold<double>(0, (sum, r) => sum + r.amount);
        final totalText = formatMoney(total);
        return AlertDialog(
          title: Text(
              draft.length > 1 ? 'تأكيد ${draft.length} مصروفات' : 'تأكيد المصروف'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < draft.length; i++) ...[
                  if (i > 0) const Divider(height: 20),
                  _resolvedExpenseTile(
                    draft[i],
                    onChangeCategory: () async {
                      // Pick from the same type (expense/income) as this row.
                      final pool = allCategories
                          .where((c) => c.isIncome == !draft[i].isExpense)
                          .toList();
                      final picked = await pickCategory(context, pool,
                          title: 'غيّر النوع إلى؟');
                      if (picked == null) return;
                      setDialogState(
                          () => draft[i] = draft[i].copyWithCategory(picked));
                    },
                  ),
                ],
                if (draft.length > 1) ...[
                  const SizedBox(height: 12),
                  Text('الإجمالي: $totalText ج',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('تأكيد')),
          ],
        );
      },
    ),
  );
  return confirmed == true ? draft : null;
}

Widget _resolvedExpenseTile(ResolvedExpense item,
    {required VoidCallback onChangeCategory}) {
  final amountText = formatMoney(item.amount);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(item.note, textDirection: ui.TextDirection.rtl),
      const SizedBox(height: 6),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Text(
            '${item.isExpense ? 'مصروف' : 'دخل'} $amountText ج',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: item.isExpense ? AppTheme.expenseRed : AppTheme.incomeGreen,
            ),
          ),
          ActionChip(
            avatar: const Icon(Icons.edit_rounded, size: 16),
            label: Text(item.category),
            onPressed: onChangeCategory,
          ),
        ],
      ),
      if (item.overCap)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('⚠ سيتجاوز الحد الشهري',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.expenseRed)),
        ),
    ],
  );
}
