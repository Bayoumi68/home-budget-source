import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../models/chat_message_model.dart';
import '../models/category_model.dart';
import '../providers/avatar_provider.dart';
import '../providers/budget_provider.dart';
import '../utils/money_format.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  // Long-press opens the message actions sheet (reply / delete).
  final VoidCallback? onLongPress;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    if (message.type == MessageType.system) {
      return _systemBubble();
    }
    return _userBubble(context);
  }

  Widget _systemBubble() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 32),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppTheme.systemMessage,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome, size: 16, color: Colors.amber),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                message.content,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, height: 1.45, color: Colors.brown),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _userBubble(BuildContext context) {
    final isExpense = message.type == MessageType.expense;
    final isDeleted = message.isDeleted;
    final isIncome = isExpense && message.content.startsWith('دخل');
    final amountColor = isIncome ? AppTheme.incomeGreen : AppTheme.expenseRed;
    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isMe ? 16 : 4),
      bottomRight: Radius.circular(isMe ? 4 : 16),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
      child: Column(
        crossAxisAlignment: align,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _miniAvatar(context),
                  const SizedBox(width: 6),
                  Text(
                    message.senderName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _nameColor(message.senderName),
                    ),
                  ),
                ],
              ),
            ),
          GestureDetector(
            onLongPress: isDeleted ? null : onLongPress,
            child: Container(
              constraints: const BoxConstraints(
                maxWidth: 300,
              ),
              decoration: BoxDecoration(
                color: isDeleted ? Colors.grey.shade200 : (isMe ? AppTheme.myMessageBubble : AppTheme.otherMessageBubble),
                borderRadius: borderRadius,
                border: (message.overCap && !isDeleted)
                    ? Border.all(color: AppTheme.expenseRed, width: 1.5)
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 56, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ((message.replyToText ?? '').isNotEmpty) _replyQuote(),
                      if (isExpense && message.amount != null && !isDeleted) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              message.category ?? '',
                              style: TextStyle(
                                fontSize: 13,
                                color: _categoryColor(message.category ?? ''),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(Icons.attach_money, size: 16, color: amountColor),
                            Text(
                              '${formatMoney(message.amount!)} ج',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: amountColor,
                              ),
                            ),
                          ],
                        ),
                        if (message.overCap)
                          const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Text(
                              '⚠ تجاوز الحد الشهري',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.expenseRed,
                              ),
                            ),
                          ),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        isDeleted
                            ? '🗑️ ${message.content}'
                            : message.type == MessageType.expense
                                ? '${context.watch<BudgetProvider>().categories.iconFor(message.category ?? '')} ${message.content}'
                                : message.content,
                        style: TextStyle(fontSize: 15, color: isDeleted ? Colors.grey.shade700 : null),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  bottom: 6,
                  right: 10,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(message.timestamp),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[500],
                        ),
                      ),
                      const SizedBox(width: 4),
                      if (isMe)
                        Icon(
                          message.status == MessageStatus.read
                              ? Icons.done_all
                              : Icons.done,
                          size: 16,
                          color: message.status == MessageStatus.read
                              ? AppTheme.accentTeal
                              : Colors.grey[400],
                        ),
                    ],
                  ),
                ),
              ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _replyQuote() {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          right: BorderSide(color: AppTheme.primaryGreen, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.replyToSender ?? '',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: AppTheme.primaryGreen,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            message.replyToText ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }

  Widget _miniAvatar(BuildContext context) {
    final bytes = context.watch<AvatarProvider>().bytesFor(message.senderId);
    if (bytes != null && bytes.isNotEmpty) {
      return CircleAvatar(radius: 11, backgroundImage: MemoryImage(bytes));
    }
    return CircleAvatar(
      radius: 11,
      backgroundColor: _nameColor(message.senderName),
      child: Text(
        message.senderName.isEmpty ? '?' : message.senderName[0].toUpperCase(),
        style: const TextStyle(fontSize: 11, color: Colors.white),
      ),
    );
  }

  Color _nameColor(String name) {
    final colors = [Colors.blue, Colors.purple, Colors.teal, Colors.orange, Colors.pink];
    return colors[name.hashCode % colors.length];
  }

  Color _categoryColor(String category) {
    if (category == 'أكل ومشروبات' || category == 'مواصلات') return Colors.brown;
    if (category == 'إيجار' || category == 'كهرباء') return Colors.deepOrange;
    return Colors.teal;
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
