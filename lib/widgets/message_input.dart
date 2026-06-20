import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../config/theme.dart';

class MessageInput extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onMic;
  final VoidCallback? onMicDown;
  final VoidCallback? onMicUp;
  final VoidCallback? onMicCancel;
  final ValueChanged<String>? onChanged;
  final bool isRecording;
  final bool isSending;
  final bool enabled;

  const MessageInput({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onMic,
    this.onMicDown,
    this.onMicUp,
    this.onMicCancel,
    this.onChanged,
    this.isRecording = false,
    this.isSending = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            GestureDetector(
              onTap: enabled && !isSending ? onMic : null,
              onLongPressStart: enabled && !isSending && !kIsWeb
                  ? (_) => (onMicDown ?? onMic)()
                  : null,
              onLongPressEnd: enabled && !isSending && !kIsWeb
                  ? (_) => (onMicUp ?? onMic)()
                  : null,
              onLongPressCancel: enabled && !isSending && !kIsWeb
                  ? () => (onMicCancel ?? onMicUp ?? onMic)()
                  : null,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isRecording ? AppTheme.expenseRed : Colors.transparent,
                ),
                child: Icon(
                  isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                  color: isRecording
                      ? Colors.white
                      : enabled
                          ? AppTheme.primaryGreen
                          : Colors.grey,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: isRecording
                      ? AppTheme.expenseRed.withOpacity(0.1)
                      : Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: controller,
                  textDirection: ui.TextDirection.rtl,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) {
                    if (enabled) onSend();
                  },
                  minLines: 1,
                  enabled: enabled && !isSending,
                  onChanged: onChanged,
                  decoration: InputDecoration(
                    hintText: isRecording
                        ? 'جاري الاستماع... اضغط الميكروفون مرة أخرى عند الانتهاء'
                        : enabled
                            ? 'اكتب الرسالة ثم أرسل بالسهم'
                            : 'صلاحية تسجيل المصاريف غير مفعلة لك',
                    hintTextDirection: ui.TextDirection.rtl,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    enabled && !isSending ? AppTheme.accentTeal : Colors.grey,
              ),
              child: IconButton(
                icon: isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.rotationY(pi),
                        child:
                            const Icon(Icons.send_rounded, color: Colors.white),
                      ),
                onPressed: enabled && !isSending ? onSend : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
