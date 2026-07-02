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
  // Links this transaction to a CategoryModel.id. Null on transactions saved
  // before the dynamic category refactor — those fall back to name matching.
  final String? categoryId;
  // The unified "raw chat text — category" description, computed once at
  // write time (see utils/expense_description.dart) and reused everywhere
  // this transaction is displayed. Null on pre-refactor transactions — use
  // [displayDescription] instead of this field directly.
  final String? description;

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
    this.categoryId,
    this.description,
  }) : date = date ?? DateTime.now();

  /// The description to show in the UI: the unified stored description if
  /// present, else a best-effort fallback built from the legacy fields so old
  /// transactions still display something sensible.
  String get displayDescription {
    final stored = description?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final n = (note ?? '').trim();
    return n.isEmpty ? category : '$category — $n';
  }

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
        'categoryId': categoryId,
        'description': description,
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
        categoryId: map['categoryId'] as String?,
        description: map['description'] as String?,
      );
}
