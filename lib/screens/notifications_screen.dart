import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/notification_provider.dart';

class NotificationsScreen extends StatefulWidget {
  final String groupId;
  const NotificationsScreen({super.key, required this.groupId});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<NotificationProvider>();
      final userId = context.read<AuthProvider>().user?.id;
      await provider.load(widget.groupId);
      if (userId != null) await provider.markAllRead(widget.groupId, userId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<NotificationProvider>();
    final userId = context.watch<AuthProvider>().user?.id;
    final items = provider.visibleItems;
    return Scaffold(
      appBar: AppBar(
        title: const Text('إشعارات العائلة'),
        actions: [
          IconButton(
            tooltip: 'مسح الإشعارات',
            icon: const Icon(Icons.delete_sweep_rounded),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('مسح الإشعارات'),
                  content: const Text(
                      'هل تريد مسح كل إشعارات العائلة من هذا الجهاز؟'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('إلغاء')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('مسح')),
                  ],
                ),
              );
              if (ok == true) await provider.clear(widget.groupId);
            },
          ),
        ],
      ),
      body: items.isEmpty
          ? const Center(child: Text('لا توجد إشعارات بعد'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemBuilder: (context, index) {
                final item = items[index];
                final read =
                    userId == null ? item.read : item.isReadFor(userId);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        read ? Colors.grey.shade300 : AppTheme.accentTeal,
                    child: Icon(
                      item.title.contains('دخل')
                          ? Icons.trending_up_rounded
                          : Icons.payments_rounded,
                      color: read ? Colors.grey.shade700 : Colors.white,
                    ),
                  ),
                  title: Text(item.title,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      '${item.body}\n${DateFormat('yyyy/MM/dd - HH:mm').format(item.timestamp)}'),
                  isThreeLine: true,
                );
              },
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemCount: items.length,
            ),
    );
  }
}
