class WalletModel {
  final String id;
  final String name;
  final double balance;
  final bool isDefault;

  WalletModel({
    required this.id,
    required this.name,
    required this.balance,
    this.isDefault = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'balance': balance,
        'isDefault': isDefault,
      };

  factory WalletModel.fromMap(Map<String, dynamic> map) => WalletModel(
        id: map['id'] ?? '',
        name: map['name'] ?? 'المحفظة الأساسية',
        balance: (map['balance'] as num?)?.toDouble() ?? 0,
        isDefault: map['isDefault'] == true,
      );

  WalletModel copyWith({
    String? id,
    String? name,
    double? balance,
    bool? isDefault,
  }) =>
      WalletModel(
        id: id ?? this.id,
        name: name ?? this.name,
        balance: balance ?? this.balance,
        isDefault: isDefault ?? this.isDefault,
      );
}
