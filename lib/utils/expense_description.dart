/// The one place an expense/income's "raw text + detected type" description is
/// built. Called once at write time and stored (TransactionModel.description,
/// the wallet-ledger entry's note) so every consumer shows the identical
/// string — never independently re-derived per screen.
String buildExpenseDescription({
  required String rawText,
  required String categoryName,
}) {
  final text = rawText.trim();
  final category = categoryName.trim();
  if (text.isEmpty) return category;
  return '$text — $category';
}

/// The chat-bubble text for an expense/income message: "مصروف/دخل {amount} ج
/// — {raw text}". The category is NOT repeated here — the bubble already
/// shows it in its own header row above this text. Keeping the
/// "مصروف"/"دخل" prefix also preserves the bubble's existing income-vs-expense
/// color detection (which checks whether content starts with "دخل").
String buildExpenseBubbleContent({
  required bool isExpense,
  required double amount,
  required String rawText,
}) {
  final prefix = isExpense ? 'مصروف' : 'دخل';
  final amountText = amount.truncateToDouble() == amount
      ? amount.toStringAsFixed(0)
      : amount.toStringAsFixed(2);
  final text = rawText.trim();
  return text.isEmpty ? '$prefix $amountText ج' : '$prefix $amountText ج — $text';
}
