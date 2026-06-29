class WalletModel {
  final String id;
  final String name;
  final String description;
  final double balance;
  final bool isDefault;
  final bool archived;
  final DateTime? updatedAt;
  final String? updatedByName;
  final String? updatedByPhone;
  // Ownership: 'admin' = a cash source the admin controls; 'member' = a single
  // member's pocket. ownerId is the member's user id for member wallets.
  final String ownerType;
  final String? ownerId;

  WalletModel({
    required this.id,
    required this.name,
    this.description = '',
    required this.balance,
    this.isDefault = false,
    this.archived = false,
    this.updatedAt,
    this.updatedByName,
    this.updatedByPhone,
    this.ownerType = 'admin',
    this.ownerId,
  });

  bool get isMemberWallet => ownerType == 'member';
  bool get isAdminWallet => ownerType == 'admin';

  /// "Name (phone)" of whoever last touched the wallet, or a dash.
  String get updatedByLabel {
    final name = (updatedByName ?? '').trim();
    final phone = (updatedByPhone ?? '').trim();
    if (name.isEmpty && phone.isEmpty) return '—';
    if (phone.isEmpty) return name;
    if (name.isEmpty) return phone;
    return '$name ($phone)';
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'balance': balance,
        'isDefault': isDefault,
        'archived': archived,
        'updatedAt': updatedAt?.toIso8601String(),
        'updatedByName': updatedByName,
        'updatedByPhone': updatedByPhone,
        'ownerType': ownerType,
        'ownerId': ownerId,
      };

  factory WalletModel.fromMap(Map<String, dynamic> map) => WalletModel(
        id: map['id'] ?? '',
        name: map['name'] ?? 'المحفظة الأساسية',
        description: (map['description'] ?? '').toString(),
        balance: (map['balance'] as num?)?.toDouble() ?? 0,
        isDefault: map['isDefault'] == true,
        archived: map['archived'] == true,
        updatedAt: DateTime.tryParse((map['updatedAt'] ?? '').toString()),
        updatedByName: map['updatedByName'],
        updatedByPhone: map['updatedByPhone'],
        ownerType: (map['ownerType'] ?? 'admin').toString(),
        ownerId: map['ownerId'],
      );

  WalletModel copyWith({
    String? id,
    String? name,
    String? description,
    double? balance,
    bool? isDefault,
    bool? archived,
    DateTime? updatedAt,
    String? updatedByName,
    String? updatedByPhone,
    String? ownerType,
    String? ownerId,
  }) =>
      WalletModel(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        balance: balance ?? this.balance,
        isDefault: isDefault ?? this.isDefault,
        archived: archived ?? this.archived,
        updatedAt: updatedAt ?? this.updatedAt,
        updatedByName: updatedByName ?? this.updatedByName,
        updatedByPhone: updatedByPhone ?? this.updatedByPhone,
        ownerType: ownerType ?? this.ownerType,
        ownerId: ownerId ?? this.ownerId,
      );
}
