class BudgetModel {
  final String category;
  final double limit;
  final double spent;
  final String period;

  BudgetModel({
    required this.category,
    required this.limit,
    this.spent = 0,
    this.period = 'monthly',
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
      };

  factory BudgetModel.fromMap(Map<String, dynamic> map) => BudgetModel(
        category: map['category'] ?? '',
        limit: (map['limit'] as num?)?.toDouble() ?? 0,
        spent: (map['spent'] as num?)?.toDouble() ?? 0,
        period: (map['period'] ?? 'monthly').toString(),
      );

  BudgetModel copyWith({
    String? category,
    double? limit,
    double? spent,
    String? period,
  }) =>
      BudgetModel(
        category: category ?? this.category,
        limit: limit ?? this.limit,
        spent: spent ?? this.spent,
        period: period ?? this.period,
      );
}
