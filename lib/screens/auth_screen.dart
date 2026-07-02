import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
  final _familyNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  final _db = DatabaseService();
  final _authService = AuthService();
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _deepLinkSub;

  bool _busy = false;
  bool _emailCreateMode = false; // false = sign in, true = create account
  bool _creatingFamily = false; // reveals the create-family form
  Future<List<FamilyMembership>>? _membershipsFuture;

  // Join-invite params (set from a deep link / URL).
  String? _inviteGroupId;
  String? _invitePhone;
  String? _inviteCode;
  String? _inviteFamilyName;
  String? _inviteTeamName;

  bool get _isJoin =>
      (_inviteCode ?? '').trim().isNotEmpty ||
      (_inviteGroupId ?? '').trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _applyInviteUri(Uri.base);
    if (widget.initialInvite != null) _applyInviteUri(widget.initialInvite!);
    _listenForInviteLinks();
    if (_isJoin) _loadInviteFamilyName();
  }

  Future<void> _listenForInviteLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _applyInviteUri(initial);
        if (mounted) setState(() {});
        if (_isJoin) _loadInviteFamilyName();
      }
      _deepLinkSub = _appLinks.uriLinkStream.listen((uri) {
        _applyInviteUri(uri);
        if (mounted) setState(() {});
        if (_isJoin) _loadInviteFamilyName();
      });
    } catch (_) {
      // Manual entry still works if deep links are unavailable.
    }
  }

  void _applyInviteUri(Uri uri) {
    final p = uri.queryParameters;
    final groupId = (p['groupId'] ?? p['familyId'] ?? '').trim();
    final phone = (p['phone'] ?? '').trim();
    final code = (p['invite'] ?? p['code'] ?? '').trim();
    if (groupId.isNotEmpty) _inviteGroupId = groupId;
    if (code.isNotEmpty) _inviteCode = code;
    if (phone.isNotEmpty) {
      _invitePhone = phone;
      // Prefill the phone the admin assigned, so the join match just works.
      if (_phoneController.text.trim().isEmpty) _phoneController.text = phone;
    }
  }

  Future<void> _loadInviteFamilyName() async {
    final code = (_inviteCode ?? '').trim();
    if (code.isNotEmpty) {
      final info = await _db.getInviteInfo(code);
      if (mounted && info != null) {
        setState(() {
          _inviteFamilyName = info['groupName'] as String?;
          _inviteTeamName = info['teamName'] as String?;
        });
      }
      return;
    }
    final id = (_inviteGroupId ?? '').trim();
    if (id.isEmpty) return;
    final group = await _db.getGroupById(id);
    if (mounted && group != null) {
      setState(() => _inviteFamilyName = group.name);
    }
  }

  @override
  void dispose() {
    _deepLinkSub?.cancel();
    _nameController.dispose();
    _phoneController.dispose();
    _familyNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ─── Auth actions ───

  Future<void> _googleSignIn() async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = await context.read<AuthProvider>().signInWithGoogle();
    if (mounted) setState(() => _busy = false);
    if (err != null) _snack(err);
  }

  Future<void> _emailSubmit() async {
    if (_busy) return;
    final email = _emailController.text.trim();
    final pass = _passwordController.text;
    if (email.isEmpty || pass.length < 6) {
      _snack('اكتب بريدًا صحيحًا وكلمة مرور من 6 أحرف على الأقل.');
      return;
    }
    setState(() => _busy = true);
    final auth = context.read<AuthProvider>();
    final err = _emailCreateMode
        ? await auth.signUpWithEmail(email, pass)
        : await auth.signInWithEmail(email, pass);
    if (mounted) setState(() => _busy = false);
    if (err != null) _snack(err);
  }

  // ─── Family actions ───

  Future<void> _createFamily() async {
    if (_busy) return;
    final familyName = _familyNameController.text.trim();
    final phone = _authService.normalizePhone(_phoneController.text.trim());
    if (familyName.isEmpty) {
      _snack('اكتب اسم العائلة.');
      return;
    }
    if (phone.length < 8) {
      _snack('اكتب رقم موبايل صحيح.');
      return;
    }
    setState(() => _busy = true);
    final auth = context.read<AuthProvider>();
    final err = await auth.createFamily(familyName, phone, _nameController.text);
    if (mounted) setState(() => _busy = false);
    if (err != null) {
      _snack(err);
      return;
    }
    _goToChat();
  }

  Future<void> _joinFamily() async {
    if (_busy) return;
    final entered = _authService.normalizePhone(_phoneController.text.trim());
    if (entered.length < 8) {
      _snack('اكتب رقم موبايلك.');
      return;
    }
    // The member's typed number must match the number the admin put in the link.
    if (_invitePhone != null &&
        _invitePhone!.isNotEmpty &&
        !_authService.phonesMatch(entered, _invitePhone!)) {
      _snack(
          'هذا الرقم لا يطابق الرقم في الدعوة. أرسل رقمك الصحيح لقائد العائلة واطلب دعوة جديدة.');
      return;
    }
    setState(() => _busy = true);
    final auth = context.read<AuthProvider>();
    final err =
        await auth.joinFamily(_inviteGroupId!, entered, _nameController.text);
    if (mounted) setState(() => _busy = false);
    if (err != null) {
      _snack(err);
      return;
    }
    _goToChat();
  }

  Future<void> _joinByCode() async {
    if (_busy) return;
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    if (name.isEmpty) {
      _snack('اكتب اسمك.');
      return;
    }
    if (phone.isEmpty) {
      _snack('اكتب رقم موبايلك — يجب أن يطابق الرقم الذي سجّله القائد لك.');
      return;
    }
    setState(() => _busy = true);
    final auth = context.read<AuthProvider>();
    final err = await auth.joinByCode(_inviteCode!, name, phone);
    if (mounted) setState(() => _busy = false);
    if (err != null) {
      _snack(err);
      return;
    }
    _goToChat();
  }

  Future<void> _openMyFamily() async {
    if (_busy) return;
    setState(() => _busy = true);
    final auth = context.read<AuthProvider>();
    final memberships = await auth.myMemberships();
    if (mounted) setState(() => _busy = false);
    if (memberships.isEmpty) {
      _snack('لا توجد عائلة مرتبطة بحسابك. أنشئ عائلة أو افتح رابط دعوة.');
      return;
    }
    FamilyMembership? chosen = memberships.first;
    if (memberships.length > 1) {
      chosen = await showDialog<FamilyMembership>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('اختر العائلة'),
          children: memberships
              .map((m) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, m),
                    child: Text(m.group.name),
                  ))
              .toList(),
        ),
      );
    }
    if (chosen == null) return;
    await auth.openMembership(chosen);
    _goToChat();
  }

  void _goToChat() {
    final auth = context.read<AuthProvider>();
    final group = auth.group;
    if (group == null || !mounted) return;
    if (auth.isTeamOnly && (auth.teamId ?? '').isNotEmpty) {
      // A worker enters their team-only view, never the family.
      Navigator.pushReplacementNamed(context, '/team-home', arguments: {
        'groupId': group.id,
        'teamId': auth.teamId,
      });
      return;
    }
    Navigator.pushReplacementNamed(context, '/chat', arguments: {
      'groupId': group.id,
      'groupName': group.name,
    });
  }

  // ─── UI ───

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
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
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: const Icon(Icons.account_balance_wallet_rounded,
                      size: 46, color: AppTheme.primaryGreen),
                ),
                const SizedBox(height: 18),
                const Text('Home Budgets',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 4),
                const Text(AppConstants.appVersion,
                    style: TextStyle(fontSize: 11, color: Colors.white60)),
                const SizedBox(height: 24),
                if (!auth.isAuthenticated)
                  _loginCard()
                else
                  _authedBody(auth),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// After sign-in: if the account already belongs to families, show a clear
  /// "enter" card (login as admin/member). Re-joining is only for brand-new
  /// members with no membership yet.
  Widget _authedBody(AuthProvider auth) {
    // Opening a one-time invite link → self-join card (no pre-registration).
    if ((_inviteCode ?? '').trim().isNotEmpty && !_creatingFamily) {
      return _joinByCodeCard(auth);
    }
    _membershipsFuture ??= auth.myMemberships();
    return FutureBuilder<List<FamilyMembership>>(
      future: _membershipsFuture,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        final memberships = snap.data ?? const <FamilyMembership>[];
        if (memberships.isNotEmpty && !_creatingFamily) {
          return _enterCard(auth, memberships);
        }
        if (_isJoin && memberships.isEmpty) return _joinCard(auth);
        return _homeChoiceCard(auth);
      },
    );
  }

  Widget _joinByCodeCard(AuthProvider auth) {
    final target = _inviteTeamName != null && _inviteTeamName!.isNotEmpty
        ? 'فريق "${_inviteTeamName!}"'
        : (_inviteFamilyName != null && _inviteFamilyName!.isNotEmpty
            ? 'عائلة "${_inviteFamilyName!}"'
            : 'العائلة');
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            'دعوة للانضمام إلى $target',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppTheme.primaryGreen, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
            'أدخل اسمك ورقم موبايلك المسجَّل عند القائد للانضمام.',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center),
        const SizedBox(height: 14),
        _whiteField(_nameController, 'اسمك', label: 'الاسم'),
        const SizedBox(height: 12),
        _whiteField(_phoneController, '01012345678',
            keyboardType: TextInputType.phone,
            rtl: false,
            label: 'رقم موبايلك المسجَّل'),
        const SizedBox(height: 18),
        _primaryButton(
            _busy ? null : _joinByCode, Icons.login_rounded, 'انضمام'),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _inviteCode = null;
                    _inviteTeamName = null;
                  }),
          child:
              const Text('ليست هذه دعوتي', style: TextStyle(color: Colors.white)),
        ),
        _signedInFooter(auth),
      ],
    );
  }

  Widget _enterCard(AuthProvider auth, List<FamilyMembership> memberships) {
    return Column(
      children: [
        const Text('مرحبًا! اختر للدخول',
            style: TextStyle(color: Colors.white70, fontSize: 15)),
        const SizedBox(height: 14),
        ...memberships.map((m) {
          final role = m.member.isWorker
              ? 'عامل'
              : (m.member.isAdmin ? 'قائد العائلة' : 'عضو');
          final roleColor = m.member.isAdmin
              ? AppTheme.gold
              : (m.member.isWorker ? Colors.orange : AppTheme.primaryGreen);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SizedBox(
              width: double.infinity,
              height: 64,
              child: ElevatedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        await auth.openMembership(m);
                        _goToChat();
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.primaryDark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.member.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.bold)),
                          Text(m.group.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.black54)),
                        ],
                      ),
                    ),
                    Text(role,
                        style: TextStyle(fontSize: 13, color: roleColor)),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 4),
        TextButton(
          onPressed:
              _busy ? null : () => setState(() => _creatingFamily = true),
          child: const Text('إنشاء عائلة جديدة',
              style: TextStyle(color: Colors.white)),
        ),
        _signedInFooter(auth),
      ],
    );
  }

  Widget _loginCard() {
    return Column(
      children: [
        Text(
          _isJoin
              ? 'سجّل الدخول لقبول دعوة العائلة'
              : 'سجّل الدخول أو أنشئ حسابك',
          style: const TextStyle(color: Colors.white70, fontSize: 15),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _busy ? null : _googleSignIn,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login_rounded),
            label: const Text('الدخول بحساب Google',
                style: TextStyle(fontSize: 17)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppTheme.primaryDark,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: const [
          Expanded(child: Divider(color: Colors.white30)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('أو', style: TextStyle(color: Colors.white70)),
          ),
          Expanded(child: Divider(color: Colors.white30)),
        ]),
        const SizedBox(height: 16),
        _whiteField(_emailController, 'بريدك الإلكتروني',
            keyboardType: TextInputType.emailAddress, rtl: false),
        const SizedBox(height: 12),
        _whiteField(_passwordController, 'كلمة المرور',
            obscure: true, rtl: false),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: OutlinedButton(
            onPressed: _busy ? null : _emailSubmit,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
            child: Text(
                _emailCreateMode ? 'إنشاء حساب بالبريد' : 'دخول بالبريد',
                style: const TextStyle(fontSize: 16)),
          ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() => _emailCreateMode = !_emailCreateMode),
          child: Text(
            _emailCreateMode
                ? 'لديك حساب؟ سجّل الدخول'
                : 'ليس لديك حساب؟ أنشئ واحدًا',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _joinCard(AuthProvider auth) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            _inviteFamilyName == null
                ? 'دعوة للانضمام إلى عائلة'
                : 'دعوة للانضمام إلى عائلة "$_inviteFamilyName"',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppTheme.primaryGreen, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'أدخل رقم موبايلك للتأكيد. يجب أن يطابق الرقم الذي خصصه لك قائد العائلة.',
          style: TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        _whiteField(_nameController, 'اسمك', label: 'الاسم'),
        const SizedBox(height: 12),
        _whiteField(_phoneController, '01012345678',
            keyboardType: TextInputType.phone,
            rtl: false,
            label: 'رقم موبايلك'),
        const SizedBox(height: 18),
        _primaryButton(
            _busy ? null : _joinFamily, Icons.login_rounded, 'انضمام للعائلة'),
        const SizedBox(height: 8),
        _signedInFooter(auth),
      ],
    );
  }

  Widget _homeChoiceCard(AuthProvider auth) {
    // Step 2: the create-family form (only after tapping "إنشاء عائلة جديدة").
    if (_creatingFamily) {
      return Column(
        children: [
          _whiteField(_nameController, 'اسمك', label: 'الاسم'),
          const SizedBox(height: 12),
          _whiteField(_familyNameController, 'مثال: عائلتي',
              label: 'اسم العائلة الجديدة'),
          const SizedBox(height: 12),
          _whiteField(_phoneController, '01012345678',
              keyboardType: TextInputType.phone,
              rtl: false,
              label: 'رقم موبايلك'),
          const SizedBox(height: 18),
          _primaryButton(
              _busy ? null : _createFamily, Icons.check_rounded, 'إنشاء العائلة'),
          const SizedBox(height: 6),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _creatingFamily = false),
            child: const Text('رجوع', style: TextStyle(color: Colors.white)),
          ),
          _signedInFooter(auth),
        ],
      );
    }
    // Step 1: just two choices, no fields.
    return Column(
      children: [
        _primaryButton(
          _busy ? null : () => setState(() => _creatingFamily = true),
          Icons.group_add_rounded,
          'إنشاء عائلة جديدة',
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _openMyFamily,
            icon: const Icon(Icons.login_rounded),
            label: const Text('تسجيل الدخول', style: TextStyle(fontSize: 17)),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: _busy ? null : _promptInviteCode,
          icon: const Icon(Icons.vpn_key_rounded,
              color: Colors.white70, size: 18),
          label: const Text('لديك كود دعوة؟ أدخله',
              style: TextStyle(color: Colors.white70)),
        ),
        TextButton.icon(
          onPressed: _busy ? null : () => _promptRestoreByPhone(auth),
          icon: const Icon(Icons.restore_rounded,
              color: Colors.white70, size: 18),
          label: const Text('استعد حساباتك برقم هاتفك',
              style: TextStyle(color: Colors.white70)),
        ),
        _signedInFooter(auth),
      ],
    );
  }

  /// Manual invite-code entry — the reliable path for the installed app, where
  /// an https invite link opens the browser instead of the app.
  Future<void> _promptInviteCode() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('أدخل كود الدعوة'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'مثال: A1B2C3D4'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('متابعة')),
        ],
      ),
    );
    if (!mounted || code == null || code.isEmpty) return;
    setState(() => _inviteCode = code.toUpperCase());
    _loadInviteFamilyName();
  }

  /// Recovery for a login that doesn't see all of its families/slots: enter the
  /// phone the slot was registered with and re-bind it to this Google account.
  Future<void> _promptRestoreByPhone(AuthProvider auth) async {
    final controller =
        TextEditingController(text: _phoneController.text.trim());
    final phone = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('استعادة حساباتي'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'أدخل رقم موبايلك المسجّل (كقائد أو كعضو) لربط كل حساباتك بهذا الدخول.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(hintText: '01012345678'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('استعادة')),
        ],
      ),
    );
    if (!mounted || phone == null || phone.isEmpty) return;
    setState(() => _busy = true);
    final err = await auth.restoreByPhone(phone);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _membershipsFuture = null; // force the picker to reload
    });
    _snack(err ?? 'تمت الاستعادة. اختر حسابك من القائمة.');
  }

  Widget _signedInFooter(AuthProvider auth) {
    final who = auth.loginEmail ?? auth.loginName ?? '';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          if (who.isNotEmpty)
            Text('مسجّل الدخول: $who',
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    await context.read<AuthProvider>().signOut();
                    if (mounted) {
                      setState(() {
                        _membershipsFuture = null;
                        _creatingFamily = false;
                      });
                    }
                  },
            child: const Text('تسجيل الخروج',
                style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _primaryButton(VoidCallback? onPressed, IconData icon, String label) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon),
        label: Text(label, style: const TextStyle(fontSize: 17)),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.accentTeal,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
    );
  }

  Widget _whiteField(
    TextEditingController controller,
    String hint, {
    TextInputType keyboardType = TextInputType.text,
    bool rtl = true,
    bool obscure = false,
    String? label,
  }) {
    final field = TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
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
    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 6),
          child: Text(label,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
        ),
        field,
      ],
    );
  }
}
