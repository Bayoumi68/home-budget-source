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
import '../services/voice_service.dart';
import '../utils/money_format.dart';

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
  final _voice = VoiceService();
  final _msgController = TextEditingController();
  late UserModel _member;
  bool _loading = true;
  bool _busy = false;
  bool _isRecording = false;
  WalletModel? _wallet;
  List<WalletEntryModel> _entries = [];
  List<WalletModel> _adminWallets = [];
  List<ChatMessage> _history = [];

  @override
  void initState() {
    super.initState();
    _member = widget.member;
    _load();
  }

  @override
  void dispose() {
    _voice.dispose();
    _msgController.dispose();
    super.dispose();
  }

  Future<void> _toggleMic() async {
    if (_isRecording) {
      await _voice.stopListening();
      if (mounted) setState(() => _isRecording = false);
      return;
    }
    final ok = await _voice.initialize(onError: (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('مشكلة في الميكروفون: $e')));
      }
    });
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_voice.lastError ?? 'الميكروفون غير متاح.')));
      }
      return;
    }
    if (mounted) setState(() => _isRecording = true);
    await _voice.startListening(
      (result, isFinal) {
        _msgController.text = result;
        _msgController.selection =
            TextSelection.fromPosition(TextPosition(offset: result.length));
      },
      onError: (e) {
        if (mounted) setState(() => _isRecording = false);
      },
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') && mounted) {
          setState(() => _isRecording = false);
        }
      },
    );
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await _db.provisionMemberWallets(widget.groupId);
      final wallets = await _db.getWalletsSync(widget.groupId);
      WalletModel? mine;
      for (final w in wallets) {
        if (w.isMemberWallet && w.ownerId == _member.id) {
          mine = w;
          break;
        }
      }
      final entries = mine == null
          ? <WalletEntryModel>[]
          : await _db.getWalletEntriesSync(widget.groupId, mine.id);
      // Conversation with this member: messages they sent, or directed to them.
      final allMsgs = await _db.getMessagesSync(widget.groupId);
      final history = allMsgs
          .where((m) =>
              !m.isDeleted &&
              m.type != MessageType.system &&
              (m.senderId == _member.id || m.targetUserId == _member.id))
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (!mounted) return;
      setState(() {
        _wallet = mine;
        _entries = entries;
        _adminWallets = wallets.where((w) => w.isAdminWallet).toList();
        _history = history;
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
              ? 'سحب من ${_member.name}'
              : 'تمويل ${_member.name}'),
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
                              '${w.name} (${formatMoney(w.balance)} ج)'),
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
    final successMsg = withdraw
        ? 'تم سحب ${formatMoney(amount)} ج'
        : 'تم تمويل ${_member.name} بـ ${formatMoney(amount)} ج';
    if (error == null && admin != null) {
      await _db.notifyMultiple(
        widget.groupId,
        title: 'حركة مالية',
        body: successMsg,
        actorId: admin.id,
        actorName: admin.name,
        targetUserIds: [admin.id, _member.id],
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ?? successMsg),
    ));
  }

  /// Admin edits a member's details. Name + limit are saved in place; the phone
  /// (the join key) is editable only while the member is still pending — once
  /// they've joined it's locked. A phone change re-keys the record.
  Future<void> _editDetails() async {
    final m = _member;
    final nameC = TextEditingController(text: m.name);
    final phoneC = TextEditingController(text: m.phone ?? '');
    final limitC = TextEditingController(
        text: m.monthlyLimit > 0 ? m.monthlyLimit.toStringAsFixed(0) : '');
    final canEditPhone = !m.joined;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تعديل بيانات ${m.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameC,
                decoration: const InputDecoration(
                    labelText: 'الاسم', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneC,
                enabled: canEditPhone,
                keyboardType: TextInputType.phone,
                textDirection: ui.TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: 'رقم الهاتف',
                  border: const OutlineInputBorder(),
                  helperText: canEditPhone
                      ? 'يمكن تعديله قبل انضمام العضو فقط'
                      : 'ثابت بعد انضمام العضو',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: limitC,
                keyboardType: TextInputType.number,
                textDirection: ui.TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'حد الإنفاق الشهري (0 = بدون)',
                  border: OutlineInputBorder(),
                ),
              ),
              if ((m.email ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text('البريد: ${m.email}',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ')),
        ],
      ),
    );
    final newName = nameC.text.trim();
    final newPhone = phoneC.text.trim();
    final newLimit =
        double.tryParse(limitC.text.trim().replaceAll(',', '.')) ??
            m.monthlyLimit;
    nameC.dispose();
    phoneC.dispose();
    limitC.dispose();
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await _db.updateMemberNameLimit(widget.groupId, m.id,
        name: newName, monthlyLimit: newLimit);
    final phoneChanged =
        canEditPhone && newPhone.isNotEmpty && newPhone != (m.phone ?? '');
    String? phoneErr;
    if (phoneChanged) {
      phoneErr = await _db.changePendingMemberPhone(widget.groupId, m, newPhone);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (phoneErr != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(phoneErr)));
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تم حفظ التعديلات')));
    if (phoneChanged) {
      // The record was re-keyed → go back so the list reloads the new record.
      Navigator.pop(context);
    } else {
      setState(() => _member =
          _member.copyWith(name: newName, monthlyLimit: newLimit));
    }
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
        targetUserId: _member.id,
      ));
      // Notify both the admin and the member of this message.
      await _db.notifyMultiple(
        widget.groupId,
        title: 'رسالة من ${admin.name}',
        body: text,
        actorId: admin.id,
        actorName: admin.name,
        targetUserIds: [admin.id, _member.id],
      );
      _msgController.clear();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('تم إرسال الرسالة إلى ${_member.name}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _historyBubble(ChatMessage m) {
    final fromMember = m.senderId == _member.id;
    return Align(
      alignment: fromMember ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: fromMember
              ? AppTheme.otherMessageBubble
              : AppTheme.myMessageBubble,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.type == MessageType.expense && m.amount != null
                ? '${m.category ?? 'مصروف'}: ${formatMoney(m.amount!)} ج'
                : m.content),
            const SizedBox(height: 2),
            Text(DateFormat('MM/dd HH:mm').format(m.timestamp),
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = _wallet;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.selfView ? 'محفظتي' : _member.name),
        actions: [
          if (!widget.selfView)
            IconButton(
              tooltip: 'تعديل البيانات',
              icon: const Icon(Icons.edit_rounded),
              onPressed: _busy ? null : _editDetails,
            ),
        ],
      ),
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
                                  Text('محفظة ${_member.name}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  if (_member.phone != null)
                                    Text(_member.phone!,
                                        style: const TextStyle(
                                            fontSize: 12, color: Colors.grey)),
                                  if ((_member.email ?? '').isNotEmpty)
                                    Text(_member.email!,
                                        style: const TextStyle(
                                            fontSize: 12, color: Colors.grey)),
                                ],
                              ),
                            ),
                            Text('${formatMoney(w?.balance ?? 0)} ج',
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
                  const Text('المحادثة مع العضو',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (_history.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('لا توجد رسائل بعد.',
                          style: TextStyle(color: Colors.grey)),
                    )
                  else
                    ..._history.map(_historyBubble),
                  const SizedBox(height: 16),
                  const Text('رسالة للعضو',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      IconButton(
                        onPressed: _busy ? null : _toggleMic,
                        tooltip: _isRecording ? 'إيقاف' : 'تحدّث',
                        icon: Icon(
                          _isRecording
                              ? Icons.stop_circle_rounded
                              : Icons.mic_rounded,
                          color: _isRecording
                              ? Colors.red
                              : AppTheme.primaryGreen,
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _msgController,
                          textDirection: ui.TextDirection.rtl,
                          decoration: const InputDecoration(
                            hintText: 'اكتب أو تحدّث برسالة تظهر في شات العضو...',
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
                  DataCell(Text(e.isDebit ? formatMoney(e.amount) : '—',
                      style: const TextStyle(color: AppTheme.incomeGreen))),
                  DataCell(Text(!e.isDebit ? formatMoney(e.amount) : '—',
                      style: const TextStyle(color: AppTheme.expenseRed))),
                  DataCell(Text(formatMoney(e.balanceAfter))),
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
