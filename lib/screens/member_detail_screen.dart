import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../config/theme.dart';
import '../models/chat_message_model.dart';
import '../models/user_model.dart';
import '../models/wallet_model.dart';
import '../models/wallet_entry_model.dart';
import '../providers/auth_provider.dart';
import '../services/database_service.dart';

/// Admin's view of a single member: their wallet, fund/withdraw, and a direct
/// message box. The message is delivered to the member's chat (targetUserId).
class MemberDetailScreen extends StatefulWidget {
  final String groupId;
  final UserModel member;
  // selfView = a member looking at their own wallet (read-only, no admin tools).
  final bool selfView;
  const MemberDetailScreen(
      {super.key,
      required this.groupId,
      required this.member,
      this.selfView = false});

  @override
  State<MemberDetailScreen> createState() => _MemberDetailScreenState();
}

class _MemberDetailScreenState extends State<MemberDetailScreen> {
  final _db = DatabaseService();
  final _money = NumberFormat('#,###');
  final _msgController = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  WalletModel? _wallet;
  List<WalletEntryModel> _entries = [];
  List<WalletModel> _adminWallets = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _msgController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await _db.provisionMemberWallets(widget.groupId);
      final wallets = await _db.getWalletsSync(widget.groupId);
      WalletModel? mine;
      for (final w in wallets) {
        if (w.isMemberWallet && w.ownerId == widget.member.id) {
          mine = w;
          break;
        }
      }
      final entries = mine == null
          ? <WalletEntryModel>[]
          : await _db.getWalletEntriesSync(widget.groupId, mine.id);
      if (!mounted) return;
      setState(() {
        _wallet = mine;
        _entries = entries;
        _adminWallets = wallets.where((w) => w.isAdminWallet).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fund({required bool withdraw}) async {
    final wallet = _wallet;
    if (wallet == null) return;
    if (_adminWallets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف محفظة نقدية لك أولًا من الإعدادات.')),
      );
      return;
    }
    var source = _adminWallets.first;
    final amountController = TextEditingController();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(withdraw
              ? 'سحب من ${widget.member.name}'
              : 'تمويل ${widget.member.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<WalletModel>(
                initialValue: source,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: withdraw ? 'إلى محفظتي' : 'من محفظتي',
                  border: const OutlineInputBorder(),
                ),
                items: _adminWallets
                    .map((w) => DropdownMenuItem(
                          value: w,
                          child: Text(
                              '${w.name} (${w.balance.toStringAsFixed(0)} ج)'),
                        ))
                    .toList(),
                onChanged: (v) => setDialog(() => source = v ?? source),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                textDirection: ui.TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'المبلغ',
                  hintText: 'المبلغ بالجنيه',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                'source': source,
                'amount': double.tryParse(
                    amountController.text.trim().replaceAll(',', '.')),
              }),
              child: Text(withdraw ? 'سحب' : 'تمويل'),
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    if (result == null || !mounted) return;
    final amount = result['amount'] as double?;
    final src = result['source'] as WalletModel;
    if (amount == null || amount <= 0) return;
    setState(() => _busy = true);
    final admin = context.read<AuthProvider>().user;
    final error = await _db.transferBetweenWallets(
      widget.groupId,
      fromWalletId: withdraw ? wallet.id : src.id,
      toWalletId: withdraw ? src.id : wallet.id,
      amount: amount,
      byName: admin?.name,
      byPhone: admin?.phone,
    );
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ??
          (withdraw
              ? 'تم سحب ${_money.format(amount)} ج'
              : 'تم تمويل ${widget.member.name} بـ ${_money.format(amount)} ج')),
    ));
  }

  Future<void> _sendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    final admin = context.read<AuthProvider>().user;
    if (admin == null) return;
    setState(() => _busy = true);
    try {
      await _db.sendMessage(ChatMessage(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        groupId: widget.groupId,
        senderId: admin.id,
        senderName: admin.name,
        senderAvatar: admin.photoUrl,
        type: MessageType.text,
        content: text,
        timestamp: DateTime.now(),
        targetUserId: widget.member.id,
      ));
      _msgController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('تم إرسال الرسالة إلى ${widget.member.name}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = _wallet;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.selfView ? 'محفظتي' : widget.member.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.account_balance_wallet_rounded,
                                color: AppTheme.incomeGreen, size: 28),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('محفظة ${widget.member.name}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  if (widget.member.phone != null)
                                    Text(widget.member.phone!,
                                        style: const TextStyle(
                                            fontSize: 12, color: Colors.grey)),
                                ],
                              ),
                            ),
                            Text('${_money.format(w?.balance ?? 0)} ج',
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.incomeGreen)),
                          ],
                        ),
                        if (!widget.selfView) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _fund(withdraw: false),
                                  icon: const Icon(Icons.add_card_rounded),
                                  label: const Text('تمويل'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed:
                                      _busy ? null : () => _fund(withdraw: true),
                                  icon: const Icon(Icons.output_rounded),
                                  label: const Text('سحب'),
                                  style: OutlinedButton.styleFrom(
                                      foregroundColor: AppTheme.expenseRed),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('حركة المحفظة',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                _ledger(),
                if (!widget.selfView) ...[
                  const SizedBox(height: 16),
                  const Text('رسالة للعضو',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _msgController,
                          textDirection: ui.TextDirection.rtl,
                          decoration: const InputDecoration(
                            hintText: 'اكتب رسالة تظهر في شات العضو...',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: _busy ? null : _sendMessage,
                        icon: const Icon(Icons.send_rounded),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }

  Widget _ledger() {
    if (_entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('لا توجد حركات بعد على هذه المحفظة.'),
      );
    }
    final rows = _entries.reversed.toList();
    final df = DateFormat('yyyy/MM/dd HH:mm');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        headingRowHeight: 34,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 56,
        columns: const [
          DataColumn(label: Text('التاريخ')),
          DataColumn(label: Text('البيان')),
          DataColumn(label: Text('وارد')),
          DataColumn(label: Text('منصرف')),
          DataColumn(label: Text('الرصيد')),
        ],
        rows: rows
            .map((e) => DataRow(cells: [
                  DataCell(Text(df.format(e.at))),
                  DataCell(Text(_statement(e))),
                  DataCell(Text(e.isDebit ? _money.format(e.amount) : '—',
                      style: const TextStyle(color: AppTheme.incomeGreen))),
                  DataCell(Text(!e.isDebit ? _money.format(e.amount) : '—',
                      style: const TextStyle(color: AppTheme.expenseRed))),
                  DataCell(Text(_money.format(e.balanceAfter))),
                ]))
            .toList(),
      ),
    );
  }

  String _statement(WalletEntryModel e) {
    final note = (e.note ?? '').trim();
    if (note.isNotEmpty) return note;
    switch (e.source) {
      case 'opening':
        return 'رصيد افتتاحي';
      case 'injection':
        return 'إيداع نقدي';
      case 'expense':
        return 'مصروف';
      case 'adjustment':
        return 'تعديل رصيد';
      case 'reversal':
        return 'إرجاع';
      case 'transfer':
        return 'تحويل';
      default:
        return e.source;
    }
  }
}
