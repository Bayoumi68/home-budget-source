import 'package:flutter/material.dart';
import '../models/budget_model.dart';
import '../models/transaction_model.dart';
import '../models/wallet_model.dart';
import '../services/database_service.dart';
import '../config/constants.dart';
import '../utils/category_utils.dart';

class BudgetProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();

  List<BudgetModel> _budgets = [];
  List<TransactionModel> _transactions = [];
  List<WalletModel> _wallets = [];
  List<String> _expenseCategories = AppConstants.expenseCategories;
  bool _loading = false;
  bool _provisioned = false;

  List<BudgetModel> get budgets => _budgets;
  List<TransactionModel> get transactions => _transactions;
  List<WalletModel> get wallets => _wallets;
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

  double get totalWalletBalance =>
      _wallets.fold<double>(0.0, (sum, wallet) => sum + wallet.balance);

  double get balance =>
      _wallets.isNotEmpty ? totalWalletBalance : totalIncome - totalExpenses;

  Future<void> loadData(String groupId) async {
    _loading = true;
    notifyListeners();
    await _ensureProvisioned(groupId);
    _expenseCategories = await _db.getExpenseCategoriesSync(groupId);
    _budgets = await _db.getBudgetsSync(groupId);
    _transactions = await _db.getTransactionsSync(groupId);
    _wallets = await _db.getWalletsSync(groupId);
    _loading = false;
    notifyListeners();
  }

  Future<void> refreshData(String groupId) async {
    await _ensureProvisioned(groupId);
    _transactions = await _db.getTransactionsSync(groupId);
    _expenseCategories = await _db.getExpenseCategoriesSync(groupId);
    _budgets = await _db.getBudgetsSync(groupId);
    _wallets = await _db.getWalletsSync(groupId);
    notifyListeners();
  }

  /// Make sure every member has their wallet — once per session, plus on demand
  /// via [reprovisionWallets] when a new member is added.
  Future<void> _ensureProvisioned(String groupId) async {
    if (_provisioned) return;
    _provisioned = true;
    try {
      await _db.provisionMemberWallets(groupId);
    } catch (_) {
      _provisioned = false; // let a later refresh retry
    }
  }

  /// Force member-wallet provisioning (e.g. right after adding a member).
  Future<void> reprovisionWallets(String groupId) async {
    try {
      await _db.provisionMemberWallets(groupId);
      _wallets = await _db.getWalletsSync(groupId);
      notifyListeners();
    } catch (_) {}
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

  Future<void> setBudget(
    String groupId,
    String category,
    double limit, {
    String period = 'monthly',
  }) async {
    _loading = true;
    notifyListeners();
    try {
      await _db.setBudget(groupId, category, limit, period: period);
      _expenseCategories = await _db.getExpenseCategoriesSync(groupId);
      _budgets = await _db.getBudgetsSync(groupId);
      _wallets = await _db.getWalletsSync(groupId);
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
      _wallets = await _db.getWalletsSync(groupId);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> removeExpenseCategory(String groupId, String category) async {
    _loading = true;
    notifyListeners();
    try {
      await _db.removeExpenseCategory(groupId, category);
      _transactions = await _db.getTransactionsSync(groupId);
      _expenseCategories = await _db.getExpenseCategoriesSync(groupId);
      _budgets = await _db.getBudgetsSync(groupId);
      _wallets = await _db.getWalletsSync(groupId);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> addWallet(
    String groupId,
    String name, {
    String description = '',
    double balance = 0,
    String? byName,
    String? byPhone,
  }) async {
    _loading = true;
    notifyListeners();
    try {
      await _db.addWallet(
        groupId,
        name,
        description: description,
        balance: balance,
        byName: byName,
        byPhone: byPhone,
      );
      _wallets = await _db.getWalletsSync(groupId);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> updateWallet(
    String groupId,
    String walletId, {
    String? name,
    String? description,
    double? limit,
    String? byName,
    String? byPhone,
  }) async {
    _loading = true;
    notifyListeners();
    try {
      await _db.updateWallet(
        groupId,
        walletId,
        name: name,
        description: description,
        limit: limit,
        byName: byName,
        byPhone: byPhone,
      );
      _wallets = await _db.getWalletsSync(groupId);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Record an external cash movement on a single wallet (deposit = DR money in,
  /// withdraw = CR money out). Balance only ever changes through such records —
  /// it is never set manually. Returns an Arabic error, or null on success.
  Future<String?> walletCashMovement(
    String groupId,
    String walletId,
    double amount, {
    required bool deposit,
    String? byName,
    String? byPhone,
  }) async {
    if (amount <= 0) return 'المبلغ غير صحيح.';
    if (!deposit) {
      final w = _wallets.firstWhere((x) => x.id == walletId,
          orElse: () => WalletModel(id: walletId, name: '', balance: 0));
      if (amount > w.balance + 0.005) {
        return 'الرصيد غير كافٍ للسحب.';
      }
    }
    _loading = true;
    notifyListeners();
    try {
      await _db.postWalletEntry(
        groupId,
        walletId,
        direction: deposit ? 'DR' : 'CR',
        amount: amount,
        source: deposit ? 'injection' : 'withdrawal',
        note: deposit ? 'إيداع نقدي' : 'سحب نقدي',
        byName: byName,
        byPhone: byPhone,
      );
      _wallets = await _db.getWalletsSync(groupId);
      return null;
    } catch (_) {
      return 'تعذّر تنفيذ العملية.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Move money between two wallets (admin funding/withdrawal).
  /// Returns an Arabic error string, or null on success.
  Future<String?> transfer(
    String groupId, {
    required String fromWalletId,
    required String toWalletId,
    required double amount,
    String? byName,
    String? byPhone,
  }) async {
    _loading = true;
    notifyListeners();
    try {
      final err = await _db.transferBetweenWallets(
        groupId,
        fromWalletId: fromWalletId,
        toWalletId: toWalletId,
        amount: amount,
        byName: byName,
        byPhone: byPhone,
      );
      _wallets = await _db.getWalletsSync(groupId);
      return err;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Archive a wallet. Returns an Arabic error string, or null on success.
  Future<String?> deleteWallet(String groupId, String walletId) async {
    _loading = true;
    notifyListeners();
    try {
      final error = await _db.deleteWallet(groupId, walletId);
      _wallets = await _db.getWalletsSync(groupId);
      return error;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
