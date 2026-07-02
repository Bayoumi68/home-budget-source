import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../config/theme.dart';
import '../models/chat_message_model.dart';
import '../providers/auth_provider.dart';
import '../services/database_service.dart';
import '../services/voice_service.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/message_input.dart';

/// One shared group thread per team — every worker on the team plus the
/// admin see and post to the same conversation. Isolated from the family's
/// main chat feed by living under families/{groupId}/teams/{teamId}/messages.
class TeamChatScreen extends StatefulWidget {
  final String groupId;
  final String teamId;
  final String teamName;

  const TeamChatScreen({
    super.key,
    required this.groupId,
    required this.teamId,
    required this.teamName,
  });

  @override
  State<TeamChatScreen> createState() => _TeamChatScreenState();
}

class _TeamChatScreenState extends State<TeamChatScreen> {
  final _db = DatabaseService();
  final _voice = VoiceService();
  final _uuid = const Uuid();
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  List<ChatMessage> _messages = const [];
  StreamSubscription<List<ChatMessage>>? _sub;
  bool _loading = true;
  bool _isSending = false;
  bool _isRecording = false;
  // WhatsApp-style reply: the message the next send will quote (null = none).
  ChatMessage? _replyTo;

  @override
  void initState() {
    super.initState();
    _sub = _db
        .watchTeamChatMessages(widget.groupId, widget.teamId)
        .listen((msgs) {
      if (!mounted) return;
      setState(() {
        _messages = msgs;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _voice.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // Press-and-hold dictate-only mic: hold to record (live text fills the box),
  // release to stop, then the user taps send. The mic never sends by itself.
  Future<void> _startMic() async {
    if (_isRecording) return;
    final ok = await _voice.initialize(
      onError: (e) => _snack('مشكلة في الميكروفون: $e'),
    );
    if (!ok) {
      _snack(_voice.lastError ?? 'الميكروفون غير متاح أو لم يُمنح الإذن.');
      return;
    }
    _controller.clear();
    if (mounted) setState(() => _isRecording = true);
    await _voice.startListening(
      (result, isFinal) {
        _controller.text = result;
        _controller.selection =
            TextSelection.fromPosition(TextPosition(offset: result.length));
      },
      onError: (e) {
        if (mounted) {
          setState(() => _isRecording = false);
          _snack('لم أستطع سماع الرسالة: $e');
        }
      },
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') && mounted) {
          setState(() => _isRecording = false);
        }
      },
    );
  }

  Future<void> _stopMic() async {
    await _voice.stopListening();
    if (mounted) setState(() => _isRecording = false);
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final user = context.read<AuthProvider>().user;
    if (text.isEmpty || user == null || _isSending) return;
    if (_isRecording) {
      await _voice.stopListening();
      if (mounted) setState(() => _isRecording = false);
    }
    setState(() => _isSending = true);
    _controller.clear();
    final replyTo = _replyTo;
    if (mounted) setState(() => _replyTo = null);
    try {
      await _db.sendTeamChatMessage(
        widget.groupId,
        widget.teamId,
        ChatMessage(
          id: _uuid.v4(),
          groupId: widget.groupId,
          senderId: user.id,
          senderName: user.name,
          senderAvatar: user.photoUrl,
          type: MessageType.text,
          content: text,
          timestamp: DateTime.now(),
          replyToId: replyTo?.id,
          replyToSender: replyTo?.senderName,
          replyToText: replyTo?.content,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _showMessageActions(ChatMessage message) async {
    if (message.isDeleted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('رد'),
              onTap: () => Navigator.pop(ctx, 'reply'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('نسخ النص'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
          ],
        ),
      ),
    );
    if (action == 'reply') {
      if (mounted) setState(() => _replyTo = message);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.content));
      _snack('تم نسخ النص');
    }
  }

  Widget _replyBanner() {
    final r = _replyTo!;
    return Container(
      color: AppTheme.systemMessage,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Container(width: 3, height: 36, color: AppTheme.primaryGreen),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('رد على ${r.senderName}',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryGreen)),
                Text(r.content,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: 'إلغاء الرد',
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    return Scaffold(
      appBar: AppBar(title: Text('محادثة ${widget.teamName}')),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(
                        child: Text('لا توجد رسائل بعد — ابدأ المحادثة'),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          return ChatBubble(
                            message: msg,
                            isMe: msg.senderId == user?.id,
                            onLongPress: () => _showMessageActions(msg),
                          );
                        },
                      ),
          ),
          if (_replyTo != null) _replyBanner(),
          MessageInput(
            controller: _controller,
            onSend: _send,
            onMicStart: () => unawaited(_startMic()),
            onMicStop: () => unawaited(_stopMic()),
            isRecording: _isRecording,
            isSending: _isSending,
          ),
        ],
      ),
    );
  }
}
