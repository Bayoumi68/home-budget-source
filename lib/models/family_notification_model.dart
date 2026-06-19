class FamilyNotificationModel {
  final String id;
  final String groupId;
  final String title;
  final String body;
  final String actorId;
  final String actorName;
  final DateTime timestamp;
  final bool read;
  final List<String> readBy;

  const FamilyNotificationModel({
    required this.id,
    required this.groupId,
    required this.title,
    required this.body,
    required this.actorId,
    required this.actorName,
    required this.timestamp,
    this.read = false,
    this.readBy = const [],
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'groupId': groupId,
        'title': title,
        'body': body,
        'actorId': actorId,
        'actorName': actorName,
        'timestamp': timestamp.toIso8601String(),
        'read': read,
        'readBy': readBy,
      };

  factory FamilyNotificationModel.fromMap(Map<String, dynamic> map) =>
      FamilyNotificationModel(
        id: map['id'] ?? '',
        groupId: map['groupId'] ?? '',
        title: map['title'] ?? '',
        body: map['body'] ?? '',
        actorId: map['actorId'] ?? '',
        actorName: map['actorName'] ?? '',
        timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
        read: map['read'] ?? false,
        readBy: (map['readBy'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
      );

  bool isReadFor(String userId) => read || readBy.contains(userId);

  FamilyNotificationModel copyWith({bool? read, List<String>? readBy}) =>
      FamilyNotificationModel(
        id: id,
        groupId: groupId,
        title: title,
        body: body,
        actorId: actorId,
        actorName: actorName,
        timestamp: timestamp,
        read: read ?? this.read,
        readBy: readBy ?? this.readBy,
      );
}
