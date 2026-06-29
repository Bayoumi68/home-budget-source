class TransactionModel {
  final String id;
  final String groupId;
  final String userId;
  final String userName;
  final double amount;
  final String category;
  final bool isExpense;
  final String? note;
  final DateTime date;
  final String? receiptUrl;
  final String? walletId;
  final String? walletName;
  final String? teamId;
  final String? teamName;
  // True when the expense exceeded the member's monthly cap (soft red flag).
  final bool overCap;

  TransactionModel({
    required this.id,
    required this.groupId,
    required this.userId,
    required this.userName,
    required this.amount,
    required this.category,
    required this.isExpense,
    this.note,
    DateTime? date,
    this.receiptUrl,
    this.walletId,
    this.walletName,
    this.teamId,
    this.teamName,
    this.overCap = false,
  }) : date = date ?? DateTime.now();

  bool get isTeamExpense => teamId != null && teamId!.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'id': id,
        'groupId': groupId,
        'userId': userId,
        'userName': userName,
        'amount': amount,
        'category': category,
        'isExpense': isExpense,
        'note': note,
        'date': date.toIso8601String(),
        'receiptUrl': receiptUrl,
        'walletId': walletId,
        'walletName': walletName,
        'teamId': teamId,
        'teamName': teamName,
        'overCap': overCap,
      };

  factory TransactionModel.fromMap(Map<String, dynamic> map) =>
      TransactionModel(
        id: map['id'] ?? '',
        groupId: map['groupId'] ?? '',
        userId: map['userId'] ?? '',
        userName: map['userName'] ?? '',
        amount: (map['amount'] as num?)?.toDouble() ?? 0,
        category: map['category'] ?? '',
        isExpense: map['isExpense'] ?? true,
        note: map['note'],
        date: DateTime.tryParse(map['date'] ?? '') ?? DateTime.now(),
        receiptUrl: map['receiptUrl'],
        walletId: map['walletId'],
        walletName: map['walletName'],
        teamId: map['teamId'],
        teamName: map['teamName'],
        overCap: map['overCap'] == true,
      );
}
