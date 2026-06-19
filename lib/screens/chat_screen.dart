import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:app_links/app_links.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/budget_provider.dart';
import '../providers/notification_provider.dart';
import '../models/chat_message_model.dart';
import '../services/voice_service.dart';
import '../services/ai_service.dart';
import '../services/local_notice_service.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/message_input.dart';
import 'members_screen.dart';
import 'group_settings_screen.dart';
import 'analytics_screen.dart';
import 'notifications_screen.dart';

class ChatScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const ChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  final _voiceService = VoiceService();
  final _localNotice = const LocalNoticeService();
  final _appLinks = AppLinks();
  bool _isRecording = false;
  bool _isSending = false;
  bool _isSyncingFamilyData = false;
  bool _isPreparingVoice = false;
  bool _isConfirmingVoice = false;
  bool _handlingInviteLink = false;
  Timer? _familyRefreshTimer;
  StreamSubscription<Uri>? _deepLinkSub;
  NotificationProvider? _notificationProvider;
  int _lastUnreadCount = 0;
  String? _lastShownNotificationId;
  bool _notificationListenerReady = false;
  String _voiceText = '';
  String? _lastSubmittedText;
  DateTime? _lastSubmittedAt;
  String? _lastParsedPreview;

  @override
  void initState() {
    super.initState();
    _listenForInviteLinks();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      context.read<ChatProvider>().subscribeMessages(widget.groupId);
      final auth = context.read<AuthProvider>();
      final userId = auth.user?.id;
      if (userId != null) {
        final notifications = context.read<NotificationProvider>();
        notifications.subscribe(widget.groupId, userId);
        _notificationProvider = notifications;
        notifications.addListener(_handleLiveNotification);
        await _localNotice.requestPermission();
      }
      await _refreshFamilyData();
      _familyRefreshTimer?.cancel();
      _familyRefreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        _refreshFamilyData(silent: true);
      });
    });
  }

  void _handleLiveNotification() {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    final latest = _notificationProvider?.latestUnreadFromOther(auth.user?.id);
    if (!_notificationListenerReady) {
      _lastShownNotificationId = latest?.id;
      _notificationListenerReady = true;
      return;
    }
    if (latest == null || latest.id == _lastShownNotificationId) return;
    _lastShownNotificationId = latest.id;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('🔔 ${latest.title}: ${latest.body}')),
    );
    _localNotice.show(latest.title, latest.body);
    setState(() => _isSyncingFamilyData = true);
    unawaited(context
        .read<BudgetProvider>()
        .refreshData(widget.groupId)
        .whenComplete(() {
      if (mounted) setState(() => _isSyncingFamilyData = false);
    }));
  }

  bool _hasInvite(Uri uri) {
    final params = uri.queryParameters;
    return (params['invite'] ?? params['code'] ?? '').trim().isNotEmpty ||
        (params['groupId'] ?? params['familyId'] ?? '').trim().isNotEmpty;
  }

  Future<void> _listenForInviteLinks() async {
    try {
      _deepLinkSub = _appLinks.uriLinkStream.listen((uri) async {
        if (!_hasInvite(uri) || !mounted || _handlingInviteLink) return;
        _handlingInviteLink = true;
        try {
          final auth = context.read<AuthProvider>();
          await auth.signOut();
          if (!mounted) return;
          Navigator.pushNamedAndRemoveUntil(
            context,
            '/auth',
            (_) => false,
            arguments: {'inviteUri': uri.toString()},
          );
        } finally {
          _handlingInviteLink = false;
        }
      });
    } catch (_) {
      // Splash/Auth still handle cold-start invite links.
    }
  }

  Future<void> _refreshFamilyData({bool silent = false}) async {
    if (!mounted) return;
    try {
      final auth = context.read<AuthProvider>();
      await context.read<BudgetProvider>().refreshData(widget.groupId);
      final notifications = context.read<NotificationProvider>();
      final newUnread = notifications.unreadCount;
      final latest = notifications.latestUnreadFromOther(auth.user?.id);
      if (silent &&
          mounted &&
          newUnread > _lastUnreadCount &&
          latest != null &&
          latest.id != _lastShownNotificationId) {
        _lastShownNotificationId = latest.id;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('🔔 ${latest.title}: ${latest.body}')),
        );
        _localNotice.show(latest.title, latest.body);
      }
      _lastUnreadCount = newUnread;
      await auth.refreshCurrentUser();
    } catch (_) {
      // Keep the screen usable during temporary network drops.
    }
  }

  @override
  void dispose() {
    _familyRefreshTimer?.cancel();
    _deepLinkSub?.cancel();
    _notificationProvider?.removeListener(_handleLiveNotification);
    _scrollController.dispose();
    _textController.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage(
      [String? forcedText, bool skipMultiConfirm = false]) async {
    if (_isSending) return;
    setState(() => _isSending = true);
    final text = (forcedText ?? _textController.text).trim();
    if (text.isEmpty) {
      if (mounted) setState(() => _isSending = false);
      return;
    }

    final now = DateTime.now();
    if (_lastSubmittedText == text &&
        _lastSubmittedAt != null &&
        now.difference(_lastSubmittedAt!) < const Duration(seconds: 6)) {
      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إرسال نفس المصروف بالفعل.')),
        );
      }
      return;
    }
    _lastSubmittedText = text;
    _lastSubmittedAt = now;

    if (_isRecording) {
      await _voiceService.stopListening();
      if (mounted) setState(() => _isRecording = false);
    }

    final multiExpenses = AIService.parseExpenseMessages(text);
    if (!skipMultiConfirm && multiExpenses.length > 1) {
      final ok = await _confirmMultipleExpenses(multiExpenses);
      if (ok != true) {
        _putTextInInput(text);
        _lastSubmittedText = null;
        _lastSubmittedAt = null;
        if (mounted) setState(() => _isSending = false);
        return;
      }
    }

    final auth = context.read<AuthProvider>();
    if (auth.user == null) {
      if (mounted) setState(() => _isSending = false);
      return;
    }

    _textController.clear();
    setState(() {
      _lastParsedPreview = null;
    });

    try {
      final chat = context.read<ChatProvider>();
      final warning =
          await chat.sendTextMessage(widget.groupId, auth.user!, text);
      await chat.refreshMessages(widget.groupId);
      await context.read<BudgetProvider>().refreshData(widget.groupId);
      await context.read<NotificationProvider>().load(widget.groupId);
      await auth.refreshCurrentUser();

      if (mounted && warning != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(warning)));
      }
    } finally {
      _voiceText = '';
      if (mounted) setState(() => _isSending = false);
    }
    _scrollToBottom();
  }

  void _putTextInInput(String text) {
    _textController.text = text;
    _textController.selection =
        TextSelection.fromPosition(TextPosition(offset: text.length));
    _updateParsedPreview(text);
  }

  Future<void> _clearChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مسح الشات'),
        content: const Text(
            'هل تريد مسح رسائل الشات من هذا الجهاز؟ المصاريف والتقارير ستظل محفوظة.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('مسح الشات')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<ChatProvider>().clearChat(widget.groupId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم مسح الشات فقط. المصاريف محفوظة.')),
      );
    }
  }

  Future<void> _deleteExpenseEntry(message) async {
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الإدخال'),
        content: const Text(
            'هل تريد حذف هذا المصروف من السجلات؟ سيتم إرجاع تأثيره للميزانية والتقارير فورًا.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('حذف وإرجاع المبلغ'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final warning = await context
        .read<ChatProvider>()
        .deleteExpenseEntry(widget.groupId, user, message);
    await context.read<ChatProvider>().refreshMessages(widget.groupId);
    await context.read<BudgetProvider>().refreshData(widget.groupId);
    await context.read<NotificationProvider>().load(widget.groupId);
    await auth.refreshCurrentUser();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(warning ?? 'تم حذف الإدخال وتحديث الميزانية')),
    );
  }

  Future<void> _openAccountDialog() async {
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null) return;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _UserAvatar(name: user.name, photoPath: user.photoUrl, radius: 42),
            const SizedBox(height: 12),
            Text(user.name,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            if (user.phone != null && user.phone!.isNotEmpty) Text(user.phone!),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final picked = await ImagePicker().pickImage(
                  source: ImageSource.gallery,
                  imageQuality: 78,
                  maxWidth: 800,
                );
                if (picked == null) return;
                await auth.updateProfilePhoto(picked.path);
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.photo_camera_back_rounded),
              label: const Text('رفع صورة للحساب'),
            ),
            const SizedBox(height: 8),
            const Text(
              'حاليًا الصورة محفوظة على هذا الجهاز فقط. في نسخة Firebase ستظهر على كل أجهزة العائلة.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareAppInvite() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('مشاركة Budget Home'),
                subtitle: Text('اختار نوع الرسالة قبل فتح واتساب.'),
              ),
              ListTile(
                leading: const Icon(Icons.group_add_rounded),
                title: const Text('دعوة فرد للانضمام لعائلتنا'),
                subtitle: const Text('يرسل رابط فيه كود العائلة الحالية.'),
                onTap: () => Navigator.pop(ctx, 'family'),
              ),
              ListTile(
                leading: const Icon(Icons.public_rounded),
                title: const Text('رابط تجربة وإنشاء عائلة جديدة'),
                subtitle:
                    const Text('يرسل رابط بدون كود دعوة، فينشئ عائلته هو.'),
                onTap: () => Navigator.pop(ctx, 'trial'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == 'family') {
      await _shareFamilyInvite();
    } else if (choice == 'trial') {
      await _shareNewFamilyTrial();
    }
  }

  Future<void> _shareFamilyInvite() async {
    final auth = context.read<AuthProvider>();
    final code = auth.group?.inviteCode;
    final groupId = auth.group?.id ?? widget.groupId;
    final installUrl = code == null
        ? '${AppConstants.appWebLink}/install.html'
        : '${AppConstants.appWebLink}/install.html?invite=$code&groupId=$groupId&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'دعوة فرد للانضمام إلى عائلتنا على Budget Home\n\n'
        'افتح الرابط التالي:\n$installUrl\n\n'
        'افتح نسخة الويب من الصفحة مباشرة على أندرويد أو آيفون بدون تثبيت.\n'
        'أندرويد: APK اختياري لو تريد تجربة تطبيق مثبت أو لو الصوت من المتصفح لم يعمل.\n'
        'آيفون: استخدم الويب، والتسجيل الصوتي قد لا يعمل بسبب قيود Safari.\n\n'
        'رابط APK الاختياري لأندرويد:\n${AppConstants.androidDownloadLink}\n'
        '${code == null ? '' : '\nكود الدعوة: $code'}';
    await Clipboard.setData(ClipboardData(text: message));
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'تم نسخ رابط التطبيق والدعوة. افتح واتساب والصقه لأي فرد.')),
      );
    }
  }

  Future<void> _shareNewFamilyTrial() async {
    final installUrl =
        '${AppConstants.appWebLink}/install.html?mode=newFamily&reset=1&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'جرّب Budget Home وأنشئ عائلتك أنت\n\n'
        'افتح الرابط التالي:\n$installUrl\n\n'
        'افتح نسخة الويب مباشرة على أندرويد أو آيفون بدون تثبيت.\n'
        'APK اختياري لأندرويد فقط لو تريد تطبيق مثبت أو صوت أفضل.\n\n'
        'هذا الرابط للتجربة وإنشاء عائلة جديدة، وليس للانضمام لعائلتنا.';
    await Clipboard.setData(ClipboardData(text: message));
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('تم نسخ رابط التجربة. افتح واتساب والصقه لمن تريد.')),
      );
    }
  }

  Future<void> _startRecording() async {
    if (_isRecording || _isSending || _isPreparingVoice || _isConfirmingVoice) {
      return;
    }
    final available = await _voiceService.initialize(
      onError: (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('مشكلة في الميكروفون: $error')),
          );
        }
      },
    );
    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(_voiceService.lastError ??
                  'المايك غير متاح أو لم يتم منح الإذن')),
        );
      }
      return;
    }
    _voiceText = '';
    setState(() => _isRecording = true);
    try {
      await _voiceService.startListening(
        (result, isFinal) {
          _voiceText = result;
          _textController.text = result;
          _textController.selection =
              TextSelection.fromPosition(TextPosition(offset: result.length));
          _updateParsedPreview(result);
        },
        onError: (error) {
          if (mounted) {
            setState(() => _isRecording = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('لم أستطع سماع الرسالة: $error')),
            );
          }
        },
        onStatus: (status) {
          if ((status == 'done' || status == 'notListening') && mounted) {
            setState(() => _isRecording = false);
            if (_voiceText.trim().isNotEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content:
                        Text('راجع الكلام المكتوب ثم اضغط سهم الإرسال للحفظ.')),
              );
            }
          }
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRecording = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر بدء التسجيل الصوتي: $e')),
      );
    }
  }

  Future<void> _stopRecording() async {
    await _voiceService.stopListening();
    setState(() => _isRecording = false);
    if (_voiceText.trim().isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('راجع الكلام المكتوب ثم اضغط سهم الإرسال للحفظ.')),
      );
    } else if (_voiceText.trim().isEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('لم أسمع كلام واضح. جرّب مرة أخرى أو اكتب المصروف.')),
      );
    }
  }

  Future<void> _finishVoiceRecordingAndConfirm() async {
    if (_isConfirmingVoice) return;
    if (!_isRecording && _voiceText.trim().isEmpty) return;
    _isConfirmingVoice = true;
    try {
      await _voiceService.stopListening();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isPreparingVoice = true;
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final text = _voiceText.trim();
      if (!mounted) return;
      setState(() => _isPreparingVoice = false);
      if (text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('لم أسمع كلام واضح. اضغط مطولًا وتكلم مرة أخرى.')),
        );
        return;
      }
      await _confirmVoiceText(text);
    } finally {
      if (mounted) {
        setState(() => _isPreparingVoice = false);
      }
      _isConfirmingVoice = false;
    }
  }

  Future<void> _confirmVoiceText(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || !mounted) return;
    final parsedItems = AIService.parseExpenseMessages(clean);
    final parsed = parsedItems.length == 1 ? parsedItems.first : null;
    final report = AIService.parseReportRequest(clean);
    final preview = parsedItems.length > 1
        ? _multipleExpenseSummary(parsedItems)
        : parsed != null
            ? AIService.formatExpenseText(parsed)
            : report != null
                ? 'طلب تقرير: $clean'
                : clean;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الرسالة الصوتية'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('سمعت منك:'),
            const SizedBox(height: 8),
            SelectableText(clean, textDirection: ui.TextDirection.rtl),
            const SizedBox(height: 12),
            Text(preview, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('هل تريد إرسالها وتسجيلها؟'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تعديل')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('نعم، أرسل')),
        ],
      ),
    );
    if (ok == true) {
      _voiceText = '';
      _textController.clear();
      if (mounted) {
        setState(() => _lastParsedPreview = null);
      }
      await _sendMessage(clean, true);
    } else {
      _putTextInInput(clean);
    }
  }

  Future<bool?> _confirmMultipleExpenses(List<Map<String, dynamic>> items) {
    final summary = _multipleExpenseSummary(items);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تأكيد ${items.length} مصروفات'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('سيتم تسجيل البنود التالية:'),
            const SizedBox(height: 8),
            SelectableText(summary, textDirection: ui.TextDirection.rtl),
            const SizedBox(height: 12),
            const Text('هل تريد حفظ كل بند كعملية منفصلة؟'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تعديل')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('نعم، سجّل الكل')),
        ],
      ),
    );
  }

  String _multipleExpenseSummary(List<Map<String, dynamic>> items) {
    final lines = <String>[];
    for (var i = 0; i < items.length; i++) {
      lines.add('${i + 1}) ${AIService.formatExpenseText(items[i])}');
    }
    final total = items
        .where((item) => item['isExpense'] == true)
        .fold<double>(0, (sum, item) => sum + (item['amount'] as double));
    final totalText = total.truncateToDouble() == total
        ? total.toStringAsFixed(0)
        : total.toStringAsFixed(2);
    lines.add('الإجمالي: $totalText ج');
    return lines.join('\n');
  }

  void _updateParsedPreview(String value) {
    final parsedItems = AIService.parseExpenseMessages(value);
    if (parsedItems.length > 1) {
      final total = parsedItems
          .where((item) => item['isExpense'] == true)
          .fold<double>(0, (sum, item) => sum + (item['amount'] as double));
      final totalText = total.truncateToDouble() == total
          ? total.toStringAsFixed(0)
          : total.toStringAsFixed(2);
      final preview =
          'سيتم تسجيل ${parsedItems.length} مصروفات بإجمالي $totalText ج';
      if (_lastParsedPreview != preview) {
        setState(() => _lastParsedPreview = preview);
      }
      return;
    }
    final parsed = parsedItems.length == 1 ? parsedItems.first : null;
    if (parsed == null) {
      if (_lastParsedPreview != null) setState(() => _lastParsedPreview = null);
      return;
    }
    final amount = parsed['amount'] as double;
    final category = parsed['category'] as String;
    final isExpense = parsed['isExpense'] as bool;
    final label = isExpense ? 'سيتم تسجيل مصروف' : 'سيتم تسجيل دخل';
    final preview = '$label: ${amount.toStringAsFixed(0)} ج — $category';
    if (_lastParsedPreview != preview) {
      setState(() => _lastParsedPreview = preview);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final budget = context.watch<BudgetProvider>();
    final notifications = context.watch<NotificationProvider>();
    final user = auth.user;

    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: _openAccountDialog,
            child: _UserAvatar(
                name: user?.name ?? widget.groupName,
                photoPath: user?.photoUrl,
                radius: 20),
          ),
        ),
        title: GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => GroupSettingsScreen(groupId: widget.groupId)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.groupName, style: const TextStyle(fontSize: 18)),
              Text(
                'الميزانية: ${NumberFormat('#,###').format(budget.balance)} ج',
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const Text(
                AppConstants.appVersion,
                style: TextStyle(fontSize: 9, color: Colors.white54),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'مشاركة التطبيق / دعوة فرد',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: _shareAppInvite,
          ),
          IconButton(
            tooltip: 'التقارير',
            icon: const Icon(Icons.analytics_rounded),
            onPressed: user?.canViewReports == true
                ? () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              AnalyticsScreen(groupId: widget.groupId)),
                    )
                : () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('التقارير غير مفعلة لحسابك')),
                    ),
          ),
          IconButton(
            tooltip: 'إشعارات العائلة',
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_rounded),
                if (notifications.unreadCount > 0)
                  Positioned(
                    right: -5,
                    top: -5,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                      child: Text(
                        notifications.unreadCount > 9
                            ? '9+'
                            : '${notifications.unreadCount}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => NotificationsScreen(groupId: widget.groupId)),
            ),
          ),
          IconButton(
            tooltip: 'أفراد العائلة',
            icon: const Icon(Icons.people_alt_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => MembersScreen(groupId: widget.groupId)),
            ),
          ),
          if (user?.isAdmin == true)
            IconButton(
              tooltip: 'الإعدادات',
              icon: const Icon(Icons.settings_rounded),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        GroupSettingsScreen(groupId: widget.groupId)),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppTheme.primaryDark,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _SummaryItem(
                    label: 'المصروفات',
                    amount: budget.totalExpenses,
                    color: AppTheme.expenseRed),
                _SummaryItem(
                    label: 'الدخل',
                    amount: budget.totalIncome,
                    color: AppTheme.incomeGreen),
                _SummaryItem(
                    label: 'المتبقي',
                    amount: budget.balance,
                    color: AppTheme.gold),
              ],
            ),
          ),
          if (_isSending ||
              _isSyncingFamilyData ||
              _isRecording ||
              _isPreparingVoice ||
              budget.loading)
            Container(
              width: double.infinity,
              color: AppTheme.systemMessage,
              child: Column(
                children: [
                  const LinearProgressIndicator(minHeight: 2),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                    child: Text(
                      _isSending
                          ? 'جاري حفظ المصروف ومزامنته مع العائلة...'
                          : budget.loading
                              ? 'جاري حفظ حدود المصروفات...'
                              : _isPreparingVoice
                                  ? 'جاري تجهيز التسجيل الصوتي...'
                                  : _isRecording
                                      ? 'استمر ضاغطًا وتكلم، وارفع صباعك عند الانتهاء.'
                                      : 'جاري تحديث بيانات العائلة...',
                      textDirection: ui.TextDirection.rtl,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.brown,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: chat.loading
                ? const Center(child: CircularProgressIndicator())
                : chat.messages.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.chat_bubble_outline_rounded,
                                size: 64, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              'لا توجد رسائل بعد\nاكتب المصروف ثم أرسله بالسهم',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(fontSize: 16, color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        itemCount: chat.messages.length,
                        itemBuilder: (context, index) {
                          final msg = chat.messages[index];
                          return ChatBubble(
                            message: msg,
                            isMe: msg.senderId == user?.id,
                            canDelete: msg.type == MessageType.expense &&
                                !msg.isDeleted &&
                                (msg.senderId == user?.id ||
                                    user?.isAdmin == true),
                            onDelete: () => _deleteExpenseEntry(msg),
                          );
                        },
                      ),
          ),
          _QuickExpenseHints(onPick: _putTextInInput),
          if (chat.hasMoreReport(widget.groupId))
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: ActionChip(
                  avatar: const Icon(Icons.navigate_next_rounded),
                  label: const Text('التالي من التقرير'),
                  onPressed: () => _sendMessage('التالي'),
                ),
              ),
            ),
          if (_lastParsedPreview != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: AppTheme.systemMessage,
              child: Text(
                _lastParsedPreview!,
                textDirection: ui.TextDirection.rtl,
                style: const TextStyle(fontSize: 13, color: Colors.brown),
              ),
            ),
          MessageInput(
            controller: _textController,
            onSend: () => _sendMessage(),
            onMic: user?.canAddExpenses == false
                ? () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('صلاحية تسجيل المصاريف غير مفعلة لك')),
                    )
                : (_isRecording ? _stopRecording : _startRecording),
            onMicDown: user?.canAddExpenses == false
                ? null
                : () => unawaited(_startRecording()),
            onMicUp: user?.canAddExpenses == false
                ? null
                : () => unawaited(_finishVoiceRecordingAndConfirm()),
            onMicCancel: user?.canAddExpenses == false
                ? null
                : () => unawaited(_finishVoiceRecordingAndConfirm()),
            isRecording: _isRecording,
            isSending: _isSending,
            enabled: user?.canAddExpenses != false && !budget.loading,
            onChanged: _updateParsedPreview,
          ),
        ],
      ),
    );
  }
}

class _UserAvatar extends StatelessWidget {
  final String name;
  final String? photoPath;
  final double radius;

  const _UserAvatar({required this.name, this.photoPath, required this.radius});

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoPath != null && photoPath!.isNotEmpty;
    if (hasPhoto && kIsWeb) {
      return CircleAvatar(
          radius: radius, backgroundImage: NetworkImage(photoPath!));
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppTheme.primaryLight,
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _QuickExpenseHints extends StatelessWidget {
  final ValueChanged<String> onPick;
  const _QuickExpenseHints({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final hints = [
      'تقرير آخر أسبوع',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          children: hints
              .map(
                (hint) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ActionChip(
                    label: Text(hint, textDirection: ui.TextDirection.rtl),
                    onPressed: () => onPick(hint),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;

  const _SummaryItem({
    required this.label,
    required this.amount,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 2),
        Text(
          '${NumberFormat('#,###').format(amount)} ج',
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 15),
        ),
      ],
    );
  }
}
