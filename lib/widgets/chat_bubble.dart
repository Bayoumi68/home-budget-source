import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../models/chat_message_model.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final bool canDelete;
  final VoidCallback? onDelete;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.canDelete = false,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (message.type == MessageType.system) {
      return _systemBubble();
    }
    return _userBubble();
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

  Widget _userBubble() {
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
              child: Text(
                message.senderName,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _nameColor(message.senderName),
                ),
              ),
            ),
          GestureDetector(
            onLongPress: canDelete && !isDeleted ? onDelete : null,
            child: Container(
              constraints: const BoxConstraints(
                maxWidth: 300,
              ),
              decoration: BoxDecoration(
                color: isDeleted ? Colors.grey.shade200 : (isMe ? AppTheme.myMessageBubble : AppTheme.otherMessageBubble),
                borderRadius: borderRadius,
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
                              '${message.amount!.toStringAsFixed(0)} ج',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: amountColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        isDeleted
                            ? '🗑️ ${message.content}'
                            : message.type == MessageType.expense
                                ? '${AppConstants.categoryIcons[message.category] ?? '📌'} ${message.content}'
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
