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
import '../models/user_model.dart';

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
  String? _inviteTeamId;
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
    final teamId = params['teamId'];
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
    if (teamId != null && teamId.trim().isNotEmpty) {
      _inviteTeamId = teamId.trim();
      _inviteFromLink = true;
      _mode = 1;
    }
  }

  Future<void> _autoJoinFromPrefilledInvite({bool force = false}) async {
    if (_autoJoinStarted && !force) return;
    final hasInviteTarget = _inviteController.text.trim().isNotEmpty ||
        (_inviteGroupId ?? '').trim().isNotEmpty;
    final hasPhone =
        _authService.normalizePhone(_phoneController.text.trim()).length >= 8;
    if (!hasInviteTarget || !hasPhone || _busy) return;
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

    final auth = context.read<AuthProvider>();
    setState(() => _busy = true);
    try {
      final existing = await _db.findMembershipsByPhone(phone);
      if (existing.isNotEmpty && mounted) {
        final selected = await _chooseExistingMembership(
          existing,
          title: 'رقمك موجود بالفعل',
          message:
              'وجدت عائلة مسجلة بهذا الرقم. افتح العائلة القديمة بدل إنشاء عائلة جديدة حتى لا تبدأ الحسابات من الصفر.',
          allowCreateNew: true,
        );
        if (selected == null) return;
        if (selected.membership != null) {
          await _openMembership(selected.membership!);
          return;
        }
      }
      final verified = await _verifyPhoneWithDemoWhatsApp(phone);
      if (!verified) return;
      await auth.ensureFirebaseIdentity();
      final user = auth.createUser(name, phone: phone, isAdmin: true);
      final group = await _db.createGroup(
        groupName,
        user.id,
        name,
        adminPhone: phone,
        adminAuthUid: user.authUid,
      );
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
    if (!_validateBasic(joining: true, requireName: false) || _busy) return;
    final phone = _authService.normalizePhone(_phoneController.text.trim());
    final code = _inviteController.text.trim().toUpperCase();
    final inviteGroupId = (_inviteGroupId ?? '').trim();

    final auth = context.read<AuthProvider>();
    setState(() => _busy = true);
    try {
      final verified = await _verifyPhoneWithDemoWhatsApp(phone);
      if (!verified) return;
      final uid = await auth.ensureFirebaseIdentity();

      var group =
          inviteGroupId.isEmpty ? null : await _db.getGroupById(inviteGroupId);
      group ??= code.isEmpty ? null : await _db.getGroupByInvite(code);
      if (group == null) {
        _snack('رابط أو كود الدعوة غير صحيح');
        return;
      }

      final teamId = (_inviteTeamId ?? '').trim();
      if (teamId.isNotEmpty) {
        final team = await _db.getTeamById(group.id, teamId);
        if (team == null) {
          _snack('دعوة الفريق غير صحيحة أو تم حذف الفريق.');
          return;
        }
        final preparedMember = await _db.getMemberByPhone(group.id, phone);
        final name = preparedMember?.name ?? _nameController.text.trim();
        if (name.isEmpty) {
          _snack('اكتب اسمك أولًا حتى يتم فتح حساب الفريق.');
          return;
        }
        final teamUser = preparedMember ??
            auth
                .createUser(
                  name,
                  phone: phone,
                )
                .copyWith(
                  canViewReports: false,
                  canManageMembers: false,
                  canManageBudgets: false,
                );
        await _db.addTeamMember(group.id, team.id, teamUser);
        if (preparedMember != null &&
            !preparedMember.isAdmin &&
            !preparedMember.canManageMembers) {
          await _db.removeMember(group.id, preparedMember.id);
        }
        final freshTeam = await _db.getTeamById(group.id, team.id) ?? team;
        await auth.setSession(
          teamUser,
          group,
          team: freshTeam,
          teamOnly: true,
        );
        if (mounted && auto) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تم فتح فريق ${freshTeam.name}')),
          );
        }
        if (mounted) {
          Navigator.pushReplacementNamed(context, '/team-home', arguments: {
            'groupId': group.id,
            'teamId': freshTeam.id,
          });
        }
        return;
      }

      final preparedMember = await _db.getMemberByPhone(group.id, phone);
      UserModel joinedUser;
      if (preparedMember == null) {
        final name = _nameController.text.trim();
        if (name.isEmpty) {
          _snack('اكتب اسمك أولًا حتى يتم إنشاء حسابك داخل العائلة.');
          return;
        }
        final newMember = auth.createUser(name, phone: phone);
        await _db.joinGroup(group.id, newMember);
        joinedUser = newMember;
      } else {
        joinedUser = uid == null
            ? preparedMember
            : await _db.bindMemberAuthUid(group.id, preparedMember, uid);
      }
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

    final auth = context.read<AuthProvider>();
    setState(() => _busy = true);
    try {
      if (familyName.isEmpty) {
        final memberships = await _db.findMembershipsByPhone(phone);
        final teamMemberships = await _db.findTeamMembershipsByPhone(phone);
        if (memberships.isEmpty) {
          if (teamMemberships.isEmpty) {
            _snack('لم أجد عائلة أو فريق مرتبط بهذا الرقم. راجع قائد العائلة.');
            return;
          }
          await _openTeamMembership(teamMemberships.first);
          return;
        }
        final selected = memberships.length == 1
            ? _MembershipChoice.open(memberships.first)
            : await _chooseExistingMembership(
                memberships,
                title: 'اختر العائلة',
                message: 'وجدت أكثر من عائلة مرتبطة بهذا الرقم.',
              );
        if (selected?.membership == null) return;
        await _openMembership(selected!.membership!);
        return;
      }
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

  Future<void> _openTeamMembership(TeamMembership membership) async {
    final auth = context.read<AuthProvider>();
    await auth.ensureFirebaseIdentity();
    await auth.setSession(
      membership.member,
      membership.group,
      team: membership.team,
      teamOnly: true,
    );
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/team-home', arguments: {
        'groupId': membership.group.id,
        'teamId': membership.team.id,
      });
    }
  }

  Future<void> _openMembership(FamilyMembership membership) async {
    final auth = context.read<AuthProvider>();
    final uid = await auth.ensureFirebaseIdentity();
    final member = uid == null
        ? membership.member
        : await _db.bindMemberAuthUid(
            membership.group.id,
            membership.member,
            uid,
          );
    await auth.setSession(member, membership.group);
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/chat', arguments: {
        'groupId': membership.group.id,
        'groupName': membership.group.name,
      });
    }
  }

  Future<_MembershipChoice?> _chooseExistingMembership(
    List<FamilyMembership> memberships, {
    required String title,
    required String message,
    bool allowCreateNew = false,
  }) {
    return showDialog<_MembershipChoice?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message),
              const SizedBox(height: 12),
              ...memberships.map(
                (item) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.home_rounded),
                    title: Text(item.group.name),
                    subtitle: Text('الدخول باسم: ${item.member.name}'),
                    onTap: () =>
                        Navigator.pop(ctx, _MembershipChoice.open(item)),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('إلغاء'),
          ),
          if (allowCreateNew)
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, const _MembershipChoice.createNew()),
              child: const Text('إنشاء عائلة جديدة رغم ذلك'),
            ),
        ],
      ),
    );
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
                Text(
                  inviteMode
                      ? 'دعوة مباشرة: اكتب رقم تليفونك وكود الدعوة ثم ادخل. لو أول مرة، اكتب اسمك أيضًا.'
                      : 'لو عندك دعوة اكتب الكود ورقم تليفونك. لو دخلت قبل كده اختار لدي عائلة واكتب رقمك فقط.',
                  style: TextStyle(fontSize: 15, color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                if (!inviteMode) ...[
                  _modeSelector(),
                  const SizedBox(height: 16),
                ],
                if (_mode == 0 || inviteMode) ...[
                  _whiteField(_nameController, 'اسمك'),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 12),
                _whiteField(_phoneController, 'رقم الموبايل 010... أو +20...',
                    keyboardType: TextInputType.phone, rtl: false),
                if (inviteMode) ...[
                  const SizedBox(height: 12),
                  _whiteField(_inviteController, 'كود الدعوة 6 أرقام',
                      keyboardType: TextInputType.number, rtl: false),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      (_inviteTeamId ?? '').trim().isNotEmpty
                          ? 'هذه دعوة فريق داخل العائلة. اكتب رقمك وكود الدعوة. لو حسابك جديد اكتب اسمك، وبعد الدخول ستجد الفريق في زر الفرق.'
                          : 'هذه دعوة عائلة. اكتب رقمك وكود الدعوة. لو حسابك جديد اكتب اسمك، وبعد الدخول سيظهر حسابك داخل العائلة.',
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
                  _whiteField(_groupNameController,
                      'اسم العائلة الموجودة أو اتركه فارغًا للبحث برقمك'),
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
        chip(0, 'عائلة جديدة', Icons.group_add_rounded),
        chip(1, 'معايا كود', Icons.login_rounded),
        chip(2, 'دخلت قبل كده', Icons.home_rounded),
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

class _MembershipChoice {
  final FamilyMembership? membership;
  final bool createNew;

  const _MembershipChoice.open(this.membership) : createNew = false;
  const _MembershipChoice.createNew()
      : membership = null,
        createNew = true;
}
