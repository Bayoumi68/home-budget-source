import 'package:flutter/material.dart';
import '../models/budget_model.dart';
import '../models/transaction_model.dart';
import '../services/database_service.dart';
import '../config/constants.dart';
import '../utils/category_utils.dart';

class BudgetProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();

  List<BudgetModel> _budgets = [];
  List<TransactionModel> _transactions = [];
  List<String> _expenseCategories = AppConstants.expenseCategories;
  bool _loading = false;

  List<BudgetModel> get budgets => _budgets;
  List<TransactionModel> get transactions => _transactions;
  List<String> get expenseCategories => _expenseCategories;
  bool get loading => _loading;

  Iterable<TransactionModel> get _currentMonthTransactions =>
      _transactions.where((t) => CategoryUtils.isThisMonth(t.date));

  double get totalExpenses => _currentMonthTransactions
      .where((t) => t.isExpense)
      .fold<double>(0.0, (sum, t) => sum + t.amount);

  double get totalIncome => _currentMonthTransactions
      .where((t) => !t.isExpense)
      .fold<double>(0.0, (sum, t) => sum + t.amount);

  double get balance => totalIncome - totalExpenses;

  Future<void> loadData(String groupId) async {
    _loading = true;
    notifyListeners();
    _expenseCategories = await _db.getExpenseCategoriesSync(groupId);
    _budgets = await _db.getBudgetsSync(groupId);
    _transactions = await _db.getTransactionsSync(groupId);
    _loading = false;
    notifyListeners();
  }

  Future<void> refreshData(String groupId) async {
    _transactions = await _db.getTransactionsSync(groupId);
    _expenseCategories = await _db.getExpenseCategoriesSync(groupId);
    _budgets = await _db.getBudgetsSync(groupId);
    notifyListeners();
  }

  Map<String, double> get categoryTotals {
    final map = <String, double>{};
    for (final t in _currentMonthTransactions.where((t) => t.isExpense)) {
      final display = _resolveDisplayCategory(t);
      map[display] = (map[display] ?? 0) + t.amount;
    }
    return map;
  }

  String _resolveDisplayCategory(TransactionModel t) {
    final directKey = CategoryUtils.key(t.category);
    for (final cat in _expenseCategories) {
      if (CategoryUtils.key(cat) == directKey) return cat;
    }

    final combined = '${t.category} ${t.note ?? ''}';
    final sorted = _expenseCategories
        .where((c) =>
            c.trim().isNotEmpty &&
            CategoryUtils.key(c) != CategoryUtils.key('أخرى'))
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final cat in sorted) {
      if (CategoryUtils.textMatchesCategory(combined, cat)) return cat;
    }
    return t.category.isEmpty ? 'أخرى' : t.category;
  }

  Future<void> setBudget(String groupId, String category, double limit) async {
    _loading = true;
    notifyListeners();
    try {
      await _db.setBudget(groupId, category, limit);
      _expenseCategories = await _db.getExpenseCategoriesSync(groupId);
      _budgets = await _db.getBudgetsSync(groupId);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> addExpenseCategory(String groupId, String category,
      {double? limit}) async {
    _loading = true;
    notifyListeners();
    try {
      await _db.addExpenseCategory(groupId, category, limit: limit);
      _transactions = await _db.getTransactionsSync(groupId);
      _expenseCategories = await _db.getExpenseCategoriesSync(groupId);
      _budgets = await _db.getBudgetsSync(groupId);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
