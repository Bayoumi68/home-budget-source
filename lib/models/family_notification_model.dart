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
  final List<String> targetUserIds;
  // When set, this notification is about that team — tapping it opens the
  // team's chat. When null, it's a family event → opens the family chat.
  // (Both chat messages and expense bubbles live in those feeds.)
  final String? teamId;

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
    this.targetUserIds = const [],
    this.teamId,
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
        'targetUserIds': targetUserIds,
        'teamId': teamId,
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
        targetUserIds: (map['targetUserIds'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        teamId: map['teamId'],
      );

  bool isVisibleFor(String userId) =>
      targetUserIds.isEmpty || targetUserIds.contains(userId);

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
        targetUserIds: targetUserIds,
        teamId: teamId,
      );
}
