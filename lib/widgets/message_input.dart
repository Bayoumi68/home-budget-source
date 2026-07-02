import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/material.dart';
import '../config/theme.dart';

class MessageInput extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  // Press-and-hold mic: hold to record, release to stop (dictation fills the
  // box, then the user reviews and taps send).
  final VoidCallback onMicStart;
  final VoidCallback onMicStop;
  final ValueChanged<String>? onChanged;
  final bool isRecording;
  final bool isSending;
  final bool enabled;

  const MessageInput({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onMicStart,
    required this.onMicStop,
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
            Listener(
              onPointerDown: enabled && !isSending
                  ? (_) => onMicStart()
                  : null,
              onPointerUp: (_) => onMicStop(),
              onPointerCancel: (_) => onMicStop(),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isRecording ? AppTheme.expenseRed : Colors.transparent,
                ),
                child: Icon(
                  isRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
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
                        ? 'جارِ الاستماع... أفلت الميكروفون عند الانتهاء'
                        : enabled
                            ? 'اكتب، أو اضغط مطوّلًا على الميكروفون وتحدّث'
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
