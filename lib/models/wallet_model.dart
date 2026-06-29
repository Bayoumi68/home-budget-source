class WalletModel {
  final String id;
  final String name;
  final String description;
  final double balance;
  // A settable guide/target for this wallet (0 = none). Never the balance —
  // balance only moves via ledger records.
  final double limit;
  final bool isDefault;
  final bool archived;
  final DateTime? updatedAt;
  final String? updatedByName;
  final String? updatedByPhone;
  // Ownership: 'admin' = a cash source the admin controls; 'member' = a single
  // member's pocket. ownerId is the member's user id for member wallets.
  final String ownerType;
  final String? ownerId;
  // Non-empty = this wallet belongs to a WORKER in that team (not a family
  // member). Family views filter these out; teams show them.
  final String? teamId;

  WalletModel({
    required this.id,
    required this.name,
    this.description = '',
    required this.balance,
    this.limit = 0,
    this.isDefault = false,
    this.archived = false,
    this.updatedAt,
    this.updatedByName,
    this.updatedByPhone,
    this.ownerType = 'admin',
    this.ownerId,
    this.teamId,
  });

  bool get isMemberWallet => ownerType == 'member';
  bool get isAdminWallet => ownerType == 'admin';

  /// A worker's wallet (belongs to a team), not a family member's.
  bool get isWorkerWallet => (teamId ?? '').trim().isNotEmpty;
  bool get isFamilyMemberWallet => isMemberWallet && !isWorkerWallet;

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
        'limit': limit,
        'isDefault': isDefault,
        'archived': archived,
        'updatedAt': updatedAt?.toIso8601String(),
        'updatedByName': updatedByName,
        'updatedByPhone': updatedByPhone,
        'ownerType': ownerType,
        'ownerId': ownerId,
        'teamId': teamId,
      };

  factory WalletModel.fromMap(Map<String, dynamic> map) => WalletModel(
        id: map['id'] ?? '',
        name: map['name'] ?? 'المحفظة الأساسية',
        description: (map['description'] ?? '').toString(),
        balance: (map['balance'] as num?)?.toDouble() ?? 0,
        limit: (map['limit'] as num?)?.toDouble() ?? 0,
        isDefault: map['isDefault'] == true,
        archived: map['archived'] == true,
        updatedAt: DateTime.tryParse((map['updatedAt'] ?? '').toString()),
        updatedByName: map['updatedByName'],
        updatedByPhone: map['updatedByPhone'],
        ownerType: (map['ownerType'] ?? 'admin').toString(),
        ownerId: map['ownerId'],
        teamId: map['teamId'],
      );

  WalletModel copyWith({
    String? id,
    String? name,
    String? description,
    double? balance,
    double? limit,
    bool? isDefault,
    bool? archived,
    DateTime? updatedAt,
    String? updatedByName,
    String? updatedByPhone,
    String? ownerType,
    String? ownerId,
    String? teamId,
  }) =>
      WalletModel(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        balance: balance ?? this.balance,
        limit: limit ?? this.limit,
        isDefault: isDefault ?? this.isDefault,
        archived: archived ?? this.archived,
        updatedAt: updatedAt ?? this.updatedAt,
        updatedByName: updatedByName ?? this.updatedByName,
        updatedByPhone: updatedByPhone ?? this.updatedByPhone,
        ownerType: ownerType ?? this.ownerType,
        ownerId: ownerId ?? this.ownerId,
        teamId: teamId ?? this.teamId,
      );
}
