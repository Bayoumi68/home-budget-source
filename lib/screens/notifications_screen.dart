import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../models/family_notification_model.dart';
import '../providers/auth_provider.dart';
import '../providers/notification_provider.dart';
import '../services/database_service.dart';
import 'team_chat_screen.dart';

class NotificationsScreen extends StatefulWidget {
  final String groupId;
  const NotificationsScreen({super.key, required this.groupId});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _db = DatabaseService();

  /// Tapping a notification jumps to where the event lives — its chat feed
  /// (both chat messages and expense bubbles live there). A team event opens
  /// that team's chat; a family event (or your own team's) just returns to the
  /// screen the bell was opened from, which already IS that chat.
  Future<void> _openEvent(FamilyNotificationModel item) async {
    final auth = context.read<AuthProvider>();
    final nav = Navigator.of(context);
    final teamId = item.teamId;
    if (teamId != null && teamId.isNotEmpty && auth.teamId != teamId) {
      final team = await _db.getTeamById(widget.groupId, teamId);
      if (team != null) {
        nav.push(MaterialPageRoute(
          builder: (_) => TeamChatScreen(
            groupId: widget.groupId,
            teamId: team.id,
            teamName: team.name,
          ),
        ));
        return;
      }
    }
    nav.pop();
  }

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
                final isChat = item.title.contains('رسالة');
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        read ? Colors.grey.shade300 : AppTheme.accentTeal,
                    child: Icon(
                      isChat
                          ? Icons.chat_bubble_rounded
                          : (item.title.contains('دخل')
                              ? Icons.trending_up_rounded
                              : Icons.payments_rounded),
                      color: read ? Colors.grey.shade700 : Colors.white,
                    ),
                  ),
                  title: Text(item.title,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      '${item.body}\n${DateFormat('yyyy/MM/dd - HH:mm').format(item.timestamp)}'),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_left_rounded,
                      color: Colors.grey),
                  onTap: () => _openEvent(item),
                );
              },
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemCount: items.length,
            ),
    );
  }
}
