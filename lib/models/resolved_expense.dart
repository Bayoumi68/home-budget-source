import 'category_model.dart';

/// A fully-resolved expense/income candidate: the offline parser's guess
/// AFTER the async hard-match against live budgets/categories/members/learned
/// keywords has already run. Produced by ChatProvider.resolveExpenseMessages
/// (no writes) and shown as-is in the mandatory confirm dialog before
/// ChatProvider.commitResolvedExpenses actually saves it — so what the user
/// sees and what gets saved are guaranteed to be the same value.
class ResolvedExpense {
  final double amount;
  final bool isExpense;
  final String note;
  final String category;
  // Links to a CategoryModel.id when the resolved category matched a real
  // stored category; null for a leftover free-text label (rare, forward-only).
  final String? categoryId;
  final bool overCap;
  final String? targetUserId;
  final String? targetUserName;

  ResolvedExpense({
    required this.amount,
    required this.isExpense,
    required this.note,
    required this.category,
    this.categoryId,
    this.overCap = false,
    this.targetUserId,
    this.targetUserName,
  });

  /// Used by the confirm dialog's "تغيير النوع" action.
  ResolvedExpense copyWithCategory(CategoryModel model) => ResolvedExpense(
        amount: amount,
        isExpense: isExpense,
        note: note,
        category: model.name,
        categoryId: model.id.isEmpty ? null : model.id,
        overCap: overCap,
        targetUserId: targetUserId,
        targetUserName: targetUserName,
      );
}
