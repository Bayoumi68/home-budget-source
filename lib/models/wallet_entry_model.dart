/// One line in a wallet's ledger (the child table linked by [walletId]).
///
/// Accounting convention: DR = money INTO the wallet (balance up),
/// CR = money OUT of the wallet (balance down). [balanceAfter] is the
/// accumulated running balance right after this entry was posted.
class WalletEntryModel {
  final String id;
  final String walletId;
  final String direction; // 'DR' | 'CR'
  final double amount; // always positive
  final double balanceAfter; // accumulated balance after this entry
  final DateTime at;
  final String source; // opening | injection | expense | adjustment | reversal
  final String? note;
  final String? byName;
  final String? byPhone;
  final String? refTransactionId;

  WalletEntryModel({
    required this.id,
    required this.walletId,
    required this.direction,
    required this.amount,
    required this.balanceAfter,
    required this.at,
    required this.source,
    this.note,
    this.byName,
    this.byPhone,
    this.refTransactionId,
  });

  bool get isDebit => direction == 'DR';

  /// +amount for a debit, -amount for a credit.
  double get signedAmount => isDebit ? amount : -amount;

  String get byLabel {
    final name = (byName ?? '').trim();
    final phone = (byPhone ?? '').trim();
    if (name.isEmpty && phone.isEmpty) return '—';
    if (phone.isEmpty) return name;
    if (name.isEmpty) return phone;
    return '$name ($phone)';
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'walletId': walletId,
        'direction': direction,
        'amount': amount,
        'balanceAfter': balanceAfter,
        'at': at.toIso8601String(),
        'source': source,
        'note': note,
        'byName': byName,
        'byPhone': byPhone,
        'refTransactionId': refTransactionId,
      };

  factory WalletEntryModel.fromMap(Map<String, dynamic> map) => WalletEntryModel(
        id: (map['id'] ?? '').toString(),
        walletId: (map['walletId'] ?? '').toString(),
        direction: (map['direction'] ?? 'DR').toString(),
        amount: (map['amount'] as num?)?.toDouble() ?? 0,
        balanceAfter: (map['balanceAfter'] as num?)?.toDouble() ?? 0,
        at: DateTime.tryParse((map['at'] ?? '').toString()) ?? DateTime.now(),
        source: (map['source'] ?? 'adjustment').toString(),
        note: map['note'],
        byName: map['byName'],
        byPhone: map['byPhone'],
        refTransactionId: map['refTransactionId'],
      );
}
