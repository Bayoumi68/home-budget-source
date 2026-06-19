enum MessageType { text, voice, system, expense }
enum MessageStatus { sending, sent, delivered, read }

class ChatMessage {
  final String id;
  final String groupId;
  final String senderId;
  final String senderName;
  final String? senderAvatar;
  final MessageType type;
  final String content;
  final double? amount;
  final String? category;
  final MessageStatus status;
  final DateTime timestamp;
  final String? voiceUrl;
  final int? voiceDuration;
  final String? transactionId;
  final bool isDeleted;

  ChatMessage({
    required this.id,
    required this.groupId,
    required this.senderId,
    required this.senderName,
    this.senderAvatar,
    required this.type,
    required this.content,
    this.amount,
    this.category,
    this.status = MessageStatus.sent,
    required this.timestamp,
    this.voiceUrl,
    this.voiceDuration,
    this.transactionId,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'groupId': groupId,
    'senderId': senderId,
    'senderName': senderName,
    'senderAvatar': senderAvatar,
    'type': type.name,
    'content': content,
    'amount': amount,
    'category': category,
    'status': status.name,
    'timestamp': timestamp.toIso8601String(),
    'voiceUrl': voiceUrl,
    'voiceDuration': voiceDuration,
    'transactionId': transactionId,
    'isDeleted': isDeleted,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'] ?? '',
    groupId: map['groupId'] ?? '',
    senderId: map['senderId'] ?? '',
    senderName: map['senderName'] ?? '',
    senderAvatar: map['senderAvatar'],
    type: MessageType.values.firstWhere((e) => e.name == map['type']),
    content: map['content'] ?? '',
    amount: (map['amount'] as num?)?.toDouble(),
    category: map['category'],
    status: MessageStatus.values.firstWhere((e) => e.name == map['status']),
    timestamp: DateTime.parse(map['timestamp'] ?? DateTime.now().toIso8601String()),
    voiceUrl: map['voiceUrl'],
    voiceDuration: map['voiceDuration'],
    transactionId: map['transactionId'],
    isDeleted: map['isDeleted'] == true,
  );
}


