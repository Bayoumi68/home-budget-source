import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../services/database_service.dart';
import '../services/auth_service.dart';

class MembersScreen extends StatefulWidget {
  final String groupId;
  const MembersScreen({super.key, required this.groupId});

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  final _db = DatabaseService();
  final _authService = AuthService();
  List<UserModel> _members = [];

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final members = await _db.getMembersSync(widget.groupId);
    if (mounted) setState(() => _members = members);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final canManage =
        auth.user?.isAdmin == true || auth.user?.canManageMembers == true;

    return Scaffold(
      appBar: AppBar(
        title: Text('أفراد العائلة (${_members.length})'),
        actions: [
          if (canManage)
            IconButton(
              tooltip: 'إضافة عضو قبل الدعوة',
              icon: const Icon(Icons.person_add_alt_rounded),
              onPressed: _showAddMemberDialog,
            ),
        ],
      ),
      body: _members.isEmpty
          ? const Center(child: Text('لا يوجد أفراد بعد'))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _members.length,
              itemBuilder: (context, index) {
                final member = _members[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: member.isAdmin
                            ? AppTheme.gold
                            : AppTheme.primaryLight,
                        child: Text(
                          member.name.isEmpty
                              ? '?'
                              : member.name[0].toUpperCase(),
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(member.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ),
                          if (member.isAdmin) _badge('قائد', AppTheme.gold),
                        ],
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (member.phone != null &&
                                member.phone!.isNotEmpty)
                              Text('الموبايل: ${member.phone}'),
                            Text('صلاحيات: ${_permissionsText(member)}'),
                            const SizedBox(height: 4),
                            Text(
                              member.monthlyLimit > 0
                                  ? 'حد شهري: ${NumberFormat('#,###').format(member.monthlyLimit)} ج — صرف: ${NumberFormat('#,###').format(member.currentSpending)} ج'
                                  : 'لا يوجد حد شهري',
                            ),
                            if (member.monthlyLimit > 0) ...[
                              const SizedBox(height: 6),
                              LinearProgressIndicator(
                                value: member.spendingPercentage,
                                color: member.spendingPercentage > .85
                                    ? AppTheme.expenseRed
                                    : AppTheme.accentTeal,
                              ),
                            ],
                          ],
                        ),
                      ),
                      trailing: canManage && member.id != auth.user?.id
                          ? PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'share')
                                  _shareInviteToMember(member);
                                if (value == 'limit') _showLimitDialog(member);
                                if (value == 'permissions')
                                  _showPermissionsDialog(member);
                                if (value == 'remove') _removeMember(member.id);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'share',
                                    child: Text('إرسال دعوة واتساب')),
                                PopupMenuItem(
                                    value: 'limit',
                                    child: Text('تحديد حد شهري')),
                                PopupMenuItem(
                                    value: 'permissions',
                                    child: Text('تعديل الصلاحيات')),
                                PopupMenuItem(
                                    value: 'remove', child: Text('حذف العضو')),
                              ],
                            )
                          : null,
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child:
          Text(text, style: const TextStyle(fontSize: 12, color: Colors.brown)),
    );
  }

  String _permissionsText(UserModel member) {
    final permissions = <String>[];
    if (member.canAddExpenses) permissions.add('تسجيل مصاريف');
    if (member.canViewReports) permissions.add('تقارير');
    if (member.canManageBudgets) permissions.add('ميزانيات');
    if (member.canManageMembers) permissions.add('أعضاء');
    return permissions.isEmpty ? 'بدون صلاحيات' : permissions.join('، ');
  }

  Future<void> _shareInviteToMember(UserModel member) async {
    final group = await _db.getGroupById(widget.groupId);
    final code = group?.inviteCode;
    if (code == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('كود الدعوة غير متاح')),
        );
      }
      return;
    }
    final permissions = _permissionsText(member);
    final inviteLanding =
        '${AppConstants.appWebLink}/install.html?invite=$code&groupId=${widget.groupId}&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'مرحبًا ${member.name},\n'
        'تمت دعوتك للانضمام إلى عائلة ${group?.name ?? ''} على Budget Home.\n\n'
        'افتح الرابط التالي:\n$inviteLanding\n\n'
        'اكتب رقم تليفونك المسجل عند قائد العائلة وكود الدعوة التالي:\n$code\n\n'
        'افتح نسخة الويب من الصفحة مباشرة على أندرويد أو آيفون بدون تثبيت.\n'
        'أندرويد: APK اختياري لو تريد تجربة تطبيق مثبت أو لو الصوت من المتصفح لم يعمل.\n'
        'آيفون: استخدم الويب، والتسجيل الصوتي قد لا يعمل بسبب قيود Safari.\n'
        'اسمك داخل التطبيق سيظهر كما سجله قائد العائلة.\n\n'
        'صلاحياتك: $permissions';
    await Clipboard.setData(ClipboardData(text: message));
    final phone = _authService.whatsappPhone(member.phone ?? '');
    final uri = phone.isEmpty
        ? Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}')
        : Uri.parse(
            'https://wa.me/$phone?text=${Uri.encodeComponent(message)}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('تم نسخ الدعوة. افتح واتساب والصقها للعضو.')),
      );
    }
  }

  Future<void> _showAddMemberDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final limitController = TextEditingController();
    var canAddExpenses = true;
    var canViewReports = true;
    var canManageBudgets = false;
    var canManageMembers = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('تجهيز دعوة عضو'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  textDirection: ui.TextDirection.rtl,
                  decoration: const InputDecoration(
                    labelText: 'اسم العضو',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  textDirection: ui.TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'رقم الموبايل',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: limitController,
                  keyboardType: TextInputType.number,
                  textDirection: ui.TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'حد شهري اختياري',
                    suffixText: 'جنيه',
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile(
                  title: const Text('يسجل مصاريف'),
                  value: canAddExpenses,
                  onChanged: (v) => setDialogState(() => canAddExpenses = v),
                ),
                SwitchListTile(
                  title: const Text('يشاهد التقارير'),
                  value: canViewReports,
                  onChanged: (v) => setDialogState(() => canViewReports = v),
                ),
                SwitchListTile(
                  title: const Text('يدير الميزانيات'),
                  value: canManageBudgets,
                  onChanged: (v) => setDialogState(() => canManageBudgets = v),
                ),
                SwitchListTile(
                  title: const Text('يدير الأعضاء'),
                  value: canManageMembers,
                  onChanged: (v) => setDialogState(() => canManageMembers = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('حفظ')),
          ],
        ),
      ),
    );

    if (saved == true) {
      final name = nameController.text.trim();
      final phone = _authService.normalizePhone(phoneController.text);
      if (name.isEmpty || phone.length < 8) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('اكتب اسم ورقم موبايل صحيحين')),
          );
        }
        return;
      }
      final member = UserModel(
        id: 'phone_$phone',
        name: name,
        phone: phone,
        isAdmin: false,
        monthlyLimit: double.tryParse(limitController.text.trim()) ?? 0,
        canAddExpenses: canAddExpenses,
        canViewReports: canViewReports,
        canManageBudgets: canManageBudgets,
        canManageMembers: canManageMembers,
      );
      await _db.joinGroup(widget.groupId, member);
      await _loadMembers();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('تم تجهيز العضو وصلاحياته. يمكنك إرسال الدعوة الآن.')),
        );
        final sendNow = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('إرسال الدعوة؟'),
            content: Text('هل تريد إرسال دعوة واتساب إلى $name الآن؟'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('لاحقًا')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('إرسال واتساب')),
            ],
          ),
        );
        if (sendNow == true) await _shareInviteToMember(member);
      }
    }
  }

  Future<void> _showLimitDialog(UserModel member) async {
    final controller = TextEditingController(
      text:
          member.monthlyLimit > 0 ? member.monthlyLimit.toStringAsFixed(0) : '',
    );
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('حد شهري — ${member.name}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          textDirection: ui.TextDirection.ltr,
          decoration: const InputDecoration(
            hintText: '0 يعني بدون حد',
            suffixText: 'جنيه',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          TextButton(
            onPressed: () => Navigator.pop(
                ctx, double.tryParse(controller.text.trim()) ?? 0),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (result != null) {
      await _db.updateMemberLimit(widget.groupId, member.id, result);
      await _loadMembers();
      if (mounted) await context.read<AuthProvider>().refreshCurrentUser();
    }
  }

  Future<void> _showPermissionsDialog(UserModel member) async {
    var canAddExpenses = member.canAddExpenses;
    var canViewReports = member.canViewReports;
    var canManageBudgets = member.canManageBudgets;
    var canManageMembers = member.canManageMembers;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('صلاحيات — ${member.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('تسجيل المصاريف بالصوت/الكتابة'),
                value: canAddExpenses,
                onChanged: (v) => setDialogState(() => canAddExpenses = v),
              ),
              SwitchListTile(
                title: const Text('عرض التقارير'),
                value: canViewReports,
                onChanged: (v) => setDialogState(() => canViewReports = v),
              ),
              SwitchListTile(
                title: const Text('إدارة حدود الميزانية'),
                value: canManageBudgets,
                onChanged: (v) => setDialogState(() => canManageBudgets = v),
              ),
              SwitchListTile(
                title: const Text('إدارة الأعضاء'),
                value: canManageMembers,
                onChanged: (v) => setDialogState(() => canManageMembers = v),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('حفظ')),
          ],
        ),
      ),
    );

    if (saved == true) {
      await _db.updateMemberPermissions(
        widget.groupId,
        member.id,
        canAddExpenses: canAddExpenses,
        canViewReports: canViewReports,
        canManageBudgets: canManageBudgets,
        canManageMembers: canManageMembers,
      );
      await _loadMembers();
    }
  }

  Future<void> _removeMember(String userId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف عضو'),
        content: const Text('هل أنت متأكد من حذف هذا العضو؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (confirmed == true) {
      await _db.removeMember(widget.groupId, userId);
      await _loadMembers();
    }
  }
}
