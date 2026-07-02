import 'package:flutter/material.dart';
import '../models/budget_model.dart';
import '../models/category_model.dart';
import '../models/transaction_model.dart';
import '../models/wallet_model.dart';
import '../services/database_service.dart';
import '../utils/category_utils.dart';

class BudgetProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();

  List<BudgetModel> _budgets = [];
  List<TransactionModel> _transactions = [];
  List<WalletModel> _wallets = [];
  List<CategoryModel> _categories = [];
  bool _loading = false;
  bool _provisioned = false;

  List<BudgetModel> get budgets => _budgets;
  List<TransactionModel> get transactions => _transactions;
  List<WalletModel> get wallets => _wallets;
  List<CategoryModel> get categories => _categories;
  List<String> get expenseCategories =>
      _categories.where((c) => !c.isIncome).map((c) => c.name).toList();
  bool get loading => _loading;

  Iterable<TransactionModel> get _currentMonthTransactions =>
      _transactions.where((t) => CategoryUtils.isThisMonth(t.date));

  double get totalExpenses => _currentMonthTransactions
      .where((t) => t.isExpense)
      .fold<double>(0.0, (sum, t) => sum + t.amount);

  double get totalIncome => _currentMonthTransactions
      .where((t) => !t.isExpense)
      .fold<double>(0.0, (sum, t) => sum + t.amount);

  // The admin's own cash — wallets NOT owned by a specific member. A family
  // member's (or worker's) wallet is THEIR asset, not the admin's; the admin
  // can still monitor it via that member's/worker's own detail screen, it just
  // doesn't count toward the admin's own total.
  double get adminWalletBalance => _wallets
      .where((w) => w.isAdminWallet)
      .fold<double>(0.0, (sum, wallet) => sum + wallet.balance);

  double get balance =>
      _wallets.isNotEmpty ? adminWalletBalance : totalIncome - totalExpenses;

  Future<void> loadData(String groupId) async {
    _loading = true;
    notifyListeners();
    await _ensureProvisioned(groupId);
    _categories = await _db.getCategoriesSync(groupId);
    _budgets = await _db.getBudgetsSync(groupId);
    _transactions = await _db.getTransactionsSync(groupId);
    _wallets = await _db.getWalletsSync(groupId);
    _loading = false;
    notifyListeners();
  }

  Future<void> refreshData(String groupId) async {
    await _ensureProvisioned(groupId);
    _transactions = await _db.getTransactionsSync(groupId);
    _categories = await _db.getCategoriesSync(groupId);
    _budgets = await _db.getBudgetsSync(groupId);
    _wallets = await _db.getWalletsSync(groupId);
    notifyListeners();
  }

  /// Make sure every member has their wallet and the family's category
  /// catalog is seeded — once per session, plus on demand via
  /// [reprovisionWallets] when a new member is added.
  Future<void> _ensureProvisioned(String groupId) async {
    if (_provisioned) return;
    _provisioned = true;
    try {
      await _db.provisionMemberWallets(groupId);
      await _db.ensureCategoriesSeeded(groupId);
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
    // Fast path: an id match is exact and unambiguous (new transactions only).
    if (t.categoryId != null && t.categoryId!.isNotEmpty) {
      for (final c in _categories) {
        if (c.id == t.categoryId) return c.name;
      }
    }
    final names = expenseCategories;
    final directKey = CategoryUtils.key(t.category);
    for (final cat in names) {
      if (CategoryUtils.key(cat) == directKey) return cat;
    }

    final combined = '${t.category} ${t.note ?? ''}';
    final sorted = names
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
      _categories = await _db.getCategoriesSync(groupId);
      _budgets = await _db.getBudgetsSync(groupId);
      _wallets = await _db.getWalletsSync(groupId);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> addExpenseCategory(
    String groupId,
    String category, {
    double? limit,
    List<String>? keywords,
    String? icon,
    bool isIncome = false,
  }) async {
    _loading = true;
    notifyListeners();
    try {
      await _db.addExpenseCategory(groupId, category,
          limit: limit, keywords: keywords, icon: icon, isIncome: isIncome);
      _transactions = await _db.getTransactionsSync(groupId);
      _categories = await _db.getCategoriesSync(groupId);
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
      _categories = await _db.getCategoriesSync(groupId);
      _budgets = await _db.getBudgetsSync(groupId);
      _wallets = await _db.getWalletsSync(groupId);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Update a category's icon (Settings edit action).
  Future<void> updateCategoryIcon(
      String groupId, String categoryId, String icon) async {
    await _db.updateCategoryIcon(groupId, categoryId, icon);
    _categories = await _db.getCategoriesSync(groupId);
    notifyListeners();
  }

  /// Update a category's optional keyword/synonym list (Settings edit action).
  Future<void> updateCategoryKeywords(
      String groupId, String categoryId, List<String> keywords) async {
    await _db.updateCategoryKeywords(groupId, categoryId, keywords);
    _categories = await _db.getCategoriesSync(groupId);
    notifyListeners();
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
