class BudgetModel {
  final String category;
  final double limit;
  final double spent;
  final String period;
  // Links this budget to a CategoryModel.id. Null on budgets created before
  // the dynamic category refactor — those fall back to name-based matching.
  final String? categoryId;

  BudgetModel({
    required this.category,
    required this.limit,
    this.spent = 0,
    this.period = 'monthly',
    this.categoryId,
  });

  double get remaining => limit - spent;
  double get percentage => limit > 0 ? (spent / limit) * 100 : 0;
  String get periodLabel {
    switch (period) {
      case 'daily':
        return 'يومي';
      case 'weekly':
        return 'أسبوعي';
      default:
        return 'شهري';
    }
  }

  Map<String, dynamic> toMap() => {
        'category': category,
        'limit': limit,
        'spent': spent,
        'period': period,
        'categoryId': categoryId,
      };

  factory BudgetModel.fromMap(Map<String, dynamic> map) => BudgetModel(
        category: map['category'] ?? '',
        limit: (map['limit'] as num?)?.toDouble() ?? 0,
        spent: (map['spent'] as num?)?.toDouble() ?? 0,
        period: (map['period'] ?? 'monthly').toString(),
        categoryId: map['categoryId'] as String?,
      );

  BudgetModel copyWith({
    String? category,
    double? limit,
    double? spent,
    String? period,
    String? categoryId,
  }) =>
      BudgetModel(
        category: category ?? this.category,
        limit: limit ?? this.limit,
        spent: spent ?? this.spent,
        period: period ?? this.period,
        categoryId: categoryId ?? this.categoryId,
      );
}
