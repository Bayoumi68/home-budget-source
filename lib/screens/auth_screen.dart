import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:app_links/app_links.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';

class AuthScreen extends StatefulWidget {
  final Uri? initialInvite;

  const AuthScreen({super.key, this.initialInvite});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _inviteController = TextEditingController();
  final _groupNameController = TextEditingController(text: 'عائلتي');
  final _otpController = TextEditingController();
  final _db = DatabaseService();
  final _authService = AuthService();
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _deepLinkSub;
  bool _busy = false;
  bool _autoJoinStarted = false;
  bool _inviteFromLink = false;
  String? _inviteGroupId;
  int _mode = 0; // 0 create, 1 join by invite, 2 existing family

  @override
  void initState() {
    super.initState();
    _applyInviteUri(Uri.base);
    if (widget.initialInvite != null) {
      _applyInviteUri(widget.initialInvite!);
    }
    _listenForInviteLinks();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _autoJoinFromPrefilledInvite());
  }

  Future<void> _listenForInviteLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _applyInviteUri(initial);
        if (mounted) setState(() {});
        await _autoJoinFromPrefilledInvite();
      }
      _deepLinkSub = _appLinks.uriLinkStream.listen((uri) async {
        _applyInviteUri(uri);
        if (mounted) setState(() {});
        await _autoJoinFromPrefilledInvite(force: true);
      });
    } catch (_) {
      // If deep links are unavailable on a device, the manual form still works.
    }
  }

  void _applyInviteUri(Uri uri) {
    final params = uri.queryParameters;
    final invite = params['invite'] ?? params['code'];
    final groupId = params['groupId'] ?? params['familyId'];
    final name = params['name'];
    final phone = params['phone'];
    if (invite != null && invite.trim().isNotEmpty) {
      _inviteController.text = invite.trim().toUpperCase();
      _inviteFromLink = true;
      _mode = 1;
    }
    if (groupId != null && groupId.trim().isNotEmpty) {
      _inviteGroupId = groupId.trim();
      _inviteFromLink = true;
      _mode = 1;
    }
    if (name != null && name.trim().isNotEmpty) {
      _nameController.text = Uri.decodeComponent(name.trim());
    }
    if (phone != null && phone.trim().isNotEmpty) {
      _phoneController.text = Uri.decodeComponent(phone.trim());
    }
  }

  Future<void> _autoJoinFromPrefilledInvite({bool force = false}) async {
    if (_autoJoinStarted && !force) return;
    final hasInviteTarget = _inviteController.text.trim().isNotEmpty ||
        (_inviteGroupId ?? '').trim().isNotEmpty;
    final hasName = _nameController.text.trim().isNotEmpty;
    final hasPhone =
        _authService.normalizePhone(_phoneController.text.trim()).length >= 8;
    if (!hasInviteTarget || !hasName || !hasPhone || _busy) return;
    _autoJoinStarted = true;
    await _joinGroup(auto: true);
  }

  @override
  void dispose() {
    _deepLinkSub?.cancel();
    _nameController.dispose();
    _phoneController.dispose();
    _inviteController.dispose();
    _groupNameController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  bool _validateBasic({bool joining = false, bool requireName = true}) {
    final name = _nameController.text.trim();
    final phone = _authService.normalizePhone(_phoneController.text.trim());
    if (requireName && name.isEmpty) {
      _snack('اكتب اسمك الأول');
      return false;
    }
    if (phone.length < 8) {
      _snack('اكتب رقم موبايل صحيح. رقم الموبايل هو هويتك داخل العائلة.');
      return false;
    }
    if (joining &&
        _inviteController.text.trim().isEmpty &&
        (_inviteGroupId ?? '').trim().isEmpty) {
      _snack('افتح رابط الدعوة مرة أخرى أو اكتب كود دعوة العائلة للانضمام');
      return false;
    }
    return true;
  }

  Future<bool> _verifyPhoneWithDemoWhatsApp(String phone) async {
    // V4.5 Firebase family test: do not leave the app to WhatsApp before creating
    // the Firestore family. This is a product test, not real phone authentication.
    // We keep the phone number as the family identity and move real Auth later.
    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text(
              'وضع اختبار Firebase: تم قبول رقم الموبايل بدون OTP حقيقي.')),
    );
    return true;
  }

  Future<void> _openWhatsAppOtp(String phone, String otp) async {
    final digits = _authService.whatsappPhone(phone);
    final message =
        'كود التحقق لتطبيق Budget Home هو: $otp\nلا تشارك هذا الكود مع أي شخص.';
    final uri =
        Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(message)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
  }

  Future<void> _createGroup() async {
    if (!_validateBasic() || _busy) return;
    final name = _nameController.text.trim();
    final phone = _authService.normalizePhone(_phoneController.text.trim());
    final groupName = _groupNameController.text.trim().isEmpty
        ? 'عائلتي'
        : _groupNameController.text.trim();

    setState(() => _busy = true);
    try {
      final verified = await _verifyPhoneWithDemoWhatsApp(phone);
      if (!verified) return;
      final auth = context.read<AuthProvider>();
      await auth.ensureFirebaseIdentity();
      final user = auth.createUser(name, phone: phone, isAdmin: true);
      final group =
          await _db.createGroup(groupName, user.id, name, adminPhone: phone);
      await auth.setSession(user, group);
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/chat', arguments: {
          'groupId': group.id,
          'groupName': group.name,
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinGroup({bool auto = false}) async {
    if (!_validateBasic(joining: true) || _busy) return;
    final name = _nameController.text.trim();
    final phone = _authService.normalizePhone(_phoneController.text.trim());
    final code = _inviteController.text.trim().toUpperCase();
    final inviteGroupId = (_inviteGroupId ?? '').trim();

    setState(() => _busy = true);
    try {
      final verified = await _verifyPhoneWithDemoWhatsApp(phone);
      if (!verified) return;
      final auth = context.read<AuthProvider>();
      await auth.ensureFirebaseIdentity();
      final user = auth.createUser(name, phone: phone);

      var group =
          inviteGroupId.isEmpty ? null : await _db.getGroupById(inviteGroupId);
      group ??= code.isEmpty ? null : await _db.getGroupByInvite(code);
      if (group == null) {
        _snack('رابط أو كود الدعوة غير صحيح');
        return;
      }

      final preparedMember = await _db.getMemberByPhone(group.id, phone);
      if (preparedMember == null) {
        _snack(
            'رقمك غير موجود ضمن أعضاء هذه العائلة. راجع قائد العائلة أولًا.');
        return;
      }
      await _db.joinGroup(group.id, user);
      final joinedUser =
          preparedMember.copyWith(id: user.id, name: name, phone: phone);
      await auth.setSession(joinedUser, group);
      if (mounted && auto) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'تم انضمام ${joinedUser.name} لعائلة ${group.name} تلقائيًا')),
        );
      }
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/chat', arguments: {
          'groupId': group.id,
          'groupName': group.name,
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openExistingFamily() async {
    if (!_validateBasic(requireName: false) || _busy) return;
    final familyName = _groupNameController.text.trim();
    final phone = _authService.normalizePhone(_phoneController.text.trim());
    if (familyName.isEmpty) {
      _snack('اكتب اسم العائلة');
      return;
    }

    setState(() => _busy = true);
    try {
      final group = await _db.getGroupByName(familyName);
      if (group == null) {
        _snack('لم أجد عائلة بهذا الاسم. راجع قائد العائلة.');
        return;
      }
      final member = await _db.getMemberByPhone(group.id, phone);
      if (member == null) {
        _snack('رقمك غير موجود في هذه العائلة. راجع قائد العائلة.');
        return;
      }
      final auth = context.read<AuthProvider>();
      final uid = await auth.ensureFirebaseIdentity();
      final linkedMember = uid == null
          ? member
          : await _db.bindMemberAuthUid(group.id, member, uid);
      await auth.setSession(linkedMember, group);
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/chat', arguments: {
          'groupId': group.id,
          'groupName': group.name,
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final inviteMode = _inviteFromLink &&
        (_inviteController.text.trim().isNotEmpty ||
            (_inviteGroupId ?? '').trim().isNotEmpty);

    return Scaffold(
      backgroundColor: AppTheme.primaryGreen,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 86,
                  height: 86,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: const Icon(
                    Icons.account_balance_wallet_rounded,
                    size: 50,
                    color: AppTheme.primaryGreen,
                  ),
                ),
                const SizedBox(height: 22),
                const Text(
                  'Budget Home',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  AppConstants.appVersion,
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 8),
                const Text(
                  'اختر ما تريد: إنشاء عائلة جديدة، الانضمام بدعوة، أو فتح عائلة موجودة.',
                  style: TextStyle(fontSize: 15, color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                if (!inviteMode) ...[
                  _modeSelector(),
                  const SizedBox(height: 16),
                ],
                if (_mode != 2) ...[
                  _whiteField(_nameController, 'اسمك'),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 12),
                _whiteField(_phoneController, 'رقم الموبايل 010... أو +20...',
                    keyboardType: TextInputType.phone, rtl: false),
                if (inviteMode) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Text(
                      'تم فتح دعوة العائلة. اكتب الاسم ورقم الموبايل فقط لو مش موجودين، وسنفتح الشات بعد الانضمام.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.primaryGreen),
                    ),
                  ),
                ] else if (_mode == 0) ...[
                  const SizedBox(height: 12),
                  _whiteField(_groupNameController, 'اسم العائلة الجديدة'),
                ] else if (_mode == 1) ...[
                  const SizedBox(height: 12),
                  _whiteField(
                      _inviteController, 'كود الدعوة عند الانضمام لعائلة'),
                ] else ...[
                  const SizedBox(height: 12),
                  _whiteField(_groupNameController, 'اسم العائلة الموجودة'),
                ],
                const SizedBox(height: 24),
                if (!inviteMode && _mode == 0) ...[
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _createGroup,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.group_add_rounded),
                      label: const Text('إنشاء عائلة جديدة',
                          style: TextStyle(fontSize: 18)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentTeal,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (!inviteMode && _mode == 2) ...[
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _openExistingFamily,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.home_rounded),
                      label: const Text('فتح عائلتي',
                          style: TextStyle(fontSize: 18)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentTeal,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24)),
                      ),
                    ),
                  ),
                ],
                if (inviteMode || _mode == 1)
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _joinGroup(),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login_rounded),
                      label: Text(
                          inviteMode ? 'الانضمام للدعوة' : 'انضمام لعائلة',
                          style: const TextStyle(fontSize: 18)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeSelector() {
    Widget chip(int value, String label, IconData icon) {
      final selected = _mode == value;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: ChoiceChip(
            selected: selected,
            showCheckmark: false,
            avatar: Icon(icon,
                size: 18,
                color: selected ? AppTheme.primaryGreen : Colors.white),
            label: Text(label, textAlign: TextAlign.center),
            labelStyle: TextStyle(
              color: selected ? AppTheme.primaryGreen : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
            selectedColor: Colors.white,
            backgroundColor: AppTheme.primaryDark,
            onSelected: (_) => setState(() => _mode = value),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip(0, 'إنشاء', Icons.group_add_rounded),
        chip(1, 'انضمام', Icons.login_rounded),
        chip(2, 'لدي عائلة', Icons.home_rounded),
      ],
    );
  }

  Widget _whiteField(
    TextEditingController controller,
    String hint, {
    TextInputType keyboardType = TextInputType.text,
    bool rtl = true,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textAlign: TextAlign.center,
      textDirection: rtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
