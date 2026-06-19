import 'user_model.dart';

class GroupModel {
  final String id;
  final String name;
  final String? photoUrl;
  final String adminId;
  final List<UserModel> members;
  final String inviteCode;
  final DateTime createdAt;
  final String currency;

  GroupModel({
    required this.id,
    required this.name,
    this.photoUrl,
    required this.adminId,
    required this.members,
    required this.inviteCode,
    DateTime? createdAt,
    this.currency = 'EGP',
  }) : createdAt = createdAt ?? DateTime.now();

  int get memberCount => members.length;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'photoUrl': photoUrl,
    'adminId': adminId,
    'memberIds': members.map((m) => m.id).toList(),
    'inviteCode': inviteCode,
    'createdAt': createdAt.toIso8601String(),
    'currency': currency,
  };

  factory GroupModel.fromMap(Map<String, dynamic> map) => GroupModel(
    id: map['id'] ?? '',
    name: map['name'] ?? '',
    photoUrl: map['photoUrl'],
    adminId: map['adminId'] ?? '',
    members: [],
    inviteCode: map['inviteCode'] ?? '',
    createdAt: DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
    currency: map['currency'] ?? 'EGP',
  );
}
