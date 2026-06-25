class TeamModel {
  final String id;
  final String groupId;
  final String name;
  final String ownerId;
  final String ownerName;
  final double limit;
  final String period;
  final List<String> memberIds;
  final Map<String, String> memberNames;
  final DateTime createdAt;
  final DateTime updatedAt;

  TeamModel({
    required this.id,
    required this.groupId,
    required this.name,
    required this.ownerId,
    required this.ownerName,
    this.limit = 0,
    this.period = 'monthly',
    this.memberIds = const [],
    this.memberNames = const {},
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  bool hasMember(String userId) => memberIds.contains(userId);
  bool canManage(String userId, {bool isAdmin = false}) =>
      isAdmin || ownerId == userId;

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
        'id': id,
        'groupId': groupId,
        'name': name,
        'ownerId': ownerId,
        'ownerName': ownerName,
        'limit': limit,
        'period': period,
        'memberIds': memberIds,
        'memberNames': memberNames,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory TeamModel.fromMap(Map<String, dynamic> map) => TeamModel(
        id: (map['id'] ?? '').toString(),
        groupId: (map['groupId'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        ownerId: (map['ownerId'] ?? '').toString(),
        ownerName: (map['ownerName'] ?? '').toString(),
        limit: (map['limit'] as num?)?.toDouble() ?? 0,
        period: (map['period'] ?? 'monthly').toString(),
        memberIds:
            (map['memberIds'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
        memberNames: (map['memberNames'] as Map?)?.map(
                (key, value) => MapEntry(key.toString(), value.toString())) ??
            const {},
        createdAt: DateTime.tryParse((map['createdAt'] ?? '').toString()) ??
            DateTime.now(),
        updatedAt: DateTime.tryParse((map['updatedAt'] ?? '').toString()) ??
            DateTime.now(),
      );

  TeamModel copyWith({
    String? id,
    String? groupId,
    String? name,
    String? ownerId,
    String? ownerName,
    double? limit,
    String? period,
    List<String>? memberIds,
    Map<String, String>? memberNames,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      TeamModel(
        id: id ?? this.id,
        groupId: groupId ?? this.groupId,
        name: name ?? this.name,
        ownerId: ownerId ?? this.ownerId,
        ownerName: ownerName ?? this.ownerName,
        limit: limit ?? this.limit,
        period: period ?? this.period,
        memberIds: memberIds ?? this.memberIds,
        memberNames: memberNames ?? this.memberNames,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
