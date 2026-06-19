class BudgetModel {
  final String category;
  final double limit;
  final double spent;

  BudgetModel({
    required this.category,
    required this.limit,
    this.spent = 0,
  });

  double get remaining => limit - spent;
  double get percentage => limit > 0 ? (spent / limit) * 100 : 0;

  Map<String, dynamic> toMap() => {
    'category': category,
    'limit': limit,
    'spent': spent,
  };

  factory BudgetModel.fromMap(Map<String, dynamic> map) => BudgetModel(
    category: map['category'] ?? '',
    limit: (map['limit'] as num?)?.toDouble() ?? 0,
    spent: (map['spent'] as num?)?.toDouble() ?? 0,
  );

  BudgetModel copyWith({String? category, double? limit, double? spent}) =>
      BudgetModel(
        category: category ?? this.category,
        limit: limit ?? this.limit,
        spent: spent ?? this.spent,
      );
}
