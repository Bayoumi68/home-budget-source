import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../models/transaction_model.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/budget_provider.dart';
import '../services/database_service.dart';
import '../utils/category_utils.dart';

class GroupSettingsScreen extends StatefulWidget {
  final String groupId;
  const GroupSettingsScreen({super.key, required this.groupId});

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  final _db = DatabaseService();
  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<BudgetProvider>().refreshData(widget.groupId);
      await _db.recalculateBudgetsForCurrentMonth(widget.groupId);
      if (mounted) {
        await context.read<BudgetProvider>().refreshData(widget.groupId);
      }
    });
  }

  Future<void> _showSetBudgetDialog(String category) async {
    final current = context
        .read<BudgetProvider>()
        .budgets
        .where((b) => _categoryKey(b.category) == _categoryKey(category))
        .firstOrNull;
    final controller = TextEditingController(
      text: current == null || current.limit <= 0
          ? ''
          : current.limit.toStringAsFixed(0),
    );
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('حد الميزانية — $category'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          textDirection: ui.TextDirection.ltr,
          decoration: const InputDecoration(
            hintText: 'المبلغ بالجنيه',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, double.tryParse(controller.text.trim())),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (amount != null && amount >= 0) {
      if (mounted) {
        await context
            .read<BudgetProvider>()
            .setBudget(widget.groupId, category, amount);
      }
    }
  }

  Future<void> _showSetMonthlyIncomeDialog() async {
    final controller = TextEditingController();
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تسجيل الدخل الشهري'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          textDirection: ui.TextDirection.ltr,
          decoration: const InputDecoration(
            hintText: 'المبلغ بالجنيه',
            prefixIcon: Icon(Icons.payments_rounded),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              double.tryParse(controller.text.trim().replaceAll(',', '.')),
            ),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (amount == null || amount <= 0 || !mounted) return;

    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null) return;

    final budgetProvider = context.read<BudgetProvider>();
    await _db.addTransaction(
      TransactionModel(
        id: _uuid.v4(),
        groupId: widget.groupId,
        userId: user.id,
        userName: user.name,
        amount: amount,
        category: 'دخل شهري',
        isExpense: false,
        note: 'تم تسجيله من الإعدادات',
      ),
    );
    await budgetProvider.refreshData(widget.groupId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text('تم تسجيل دخل شهري بقيمة ${amount.toStringAsFixed(0)} ج')),
    );
  }

  Future<void> _showAddCategoryDialog() async {
    final nameController = TextEditingController();
    final limitController = TextEditingController();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة نوع مصروف جديد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              textDirection: ui.TextDirection.rtl,
              decoration: const InputDecoration(
                labelText: 'اسم النوع',
                hintText: 'مثال: صيانة السيارة، مصروف محمد، علاج',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: limitController,
              keyboardType: TextInputType.number,
              textDirection: ui.TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'الحد الشهري اختياري',
                hintText: 'مثال: 1500',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'بعد الإضافة، لو كتبت اسم النوع في الشات سيتم ربط المصروف به بدل “أخرى”.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx, {
                'name': name,
                'limit': double.tryParse(limitController.text.trim()),
              });
            },
            child: const Text('إضافة'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (!mounted) return;
    final name = result['name'] as String;
    final limit = result['limit'] as double?;
    final budgetProvider = context.read<BudgetProvider>();
    await budgetProvider.addExpenseCategory(widget.groupId, name, limit: limit);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تمت إضافة نوع المصروف: $name')),
    );
  }

  Future<void> _shareInviteOnWhatsApp() async {
    final auth = context.read<AuthProvider>();
    final code = auth.group?.inviteCode;
    if (code == null) return;
    final groupId = auth.group?.id ?? widget.groupId;
    final inviteLanding =
        '${AppConstants.appWebLink}/install.html?invite=$code&groupId=$groupId&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'دعوة فرد للانضمام إلى عائلتنا على Budget Home\n\n'
        'افتح الرابط التالي:\n$inviteLanding\n\n'
        'أندرويد: من الصفحة اضغط تحميل وتثبيت APK، وبعد التثبيت ارجع واضغط فتح الدعوة في التطبيق.\n'
        'آيفون: لا يثبت APK، اضغط فتح نسخة الويب من نفس الصفحة.\n\n'
        'رابط أندرويد للتثبيت:\n${AppConstants.androidDownloadLink}\n\n'
        'كود الدعوة: $code';
    await Clipboard.setData(ClipboardData(text: message));
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('تم نسخ الدعوة. افتح واتساب والصقها لأي فرد.')),
      );
    }
  }

  Future<void> _resetThisDevice() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إعادة ضبط هذا الجهاز'),
        content: const Text(
            'سيتم مسح الجلسة المحلية فقط من هذا الهاتف والرجوع لشاشة البداية. بيانات العائلة على Firebase لن تُحذف.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إعادة الضبط')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AuthProvider>().signOut();
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(context, '/auth', (_) => false);
    }
  }

  Future<void> _shareAppTrialLink() async {
    final trialUrl =
        '${AppConstants.appWebLink}/install.html?mode=newFamily&reset=1&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'جرّب Budget Home وأنشئ عائلتك أنت\n\n'
        'افتح الرابط التالي:\n$trialUrl\n\n'
        'أندرويد: حمّل وثبّت APK من الصفحة.\n'
        'آيفون: افتح نسخة الويب من نفس الصفحة بدون تثبيت.\n\n'
        'هذا الرابط للتجربة وإنشاء عائلة جديدة، وليس للانضمام لعائلتنا.';
    await Clipboard.setData(ClipboardData(text: message));
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('تم نسخ رابط تجربة التطبيق. افتح واتساب والصقه لأي شخص.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final auth = context.watch<AuthProvider>();
    final budget = context.watch<BudgetProvider>();
    final canManageBudgets =
        auth.user?.isAdmin == true || auth.user?.canManageBudgets == true;
    final categories = budget.expenseCategories;

    return Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات'),
        actions: [
          IconButton(
            tooltip: 'إعادة حساب الحدود',
            onPressed: budget.loading
                ? null
                : () async {
                    final budgetProvider = context.read<BudgetProvider>();
                    await _db.recalculateBudgetsForCurrentMonth(widget.groupId);
                    if (mounted) {
                      await budgetProvider.refreshData(widget.groupId);
                    }
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (budget.loading) ...[
            const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 8),
            const Text(
              'جاري حفظ التغييرات... انتظر لحظة قبل تسجيل مصروف جديد.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
          ],
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_done_rounded,
                  color: AppTheme.primaryGreen),
              title: const Text('نسخة Firebase النشطة'),
              subtitle:
                  Text('${AppConstants.appVersion}\nGroup: ${widget.groupId}'),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: const Text('الوضع الليلي'),
              subtitle: const Text('تغيير مظهر التطبيق'),
              secondary:
                  Icon(theme.isDark ? Icons.dark_mode : Icons.light_mode),
              value: theme.isDark,
              onChanged: (_) => theme.toggle(),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading:
                      const Icon(Icons.vpn_key_rounded, color: AppTheme.gold),
                  title: const Text('كود دعوة العائلة'),
                  subtitle: Text(auth.group?.inviteCode ?? 'غير متاح'),
                  trailing: const Icon(Icons.copy_rounded),
                  onTap: () async {
                    final code = auth.group?.inviteCode;
                    if (code == null) return;
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('تم نسخ كود الدعوة: $code')),
                      );
                    }
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.share_rounded,
                      color: AppTheme.incomeGreen),
                  title: const Text('دعوة فرد للعائلة'),
                  subtitle: const Text(
                      'يرسل صفحة تثبيت APK ثم فتح الدعوة داخل التطبيق.'),
                  trailing: const Icon(Icons.send_rounded),
                  onTap: _shareInviteOnWhatsApp,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.public_rounded,
                      color: AppTheme.primaryGreen),
                  title: const Text('رابط تجربة التطبيق لأي شخص'),
                  subtitle: const Text('يفتح التطبيق ويقدر ينشئ عائلته هو.'),
                  trailing: const Icon(Icons.link_rounded),
                  onTap: _shareAppTrialLink,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.payments_rounded,
                  color: AppTheme.incomeGreen),
              title: const Text('الدخل الشهري'),
              subtitle: const Text('سجل دخل الشهر من هنا بدل اقتراحات الشات.'),
              trailing: const Icon(Icons.edit_rounded),
              onTap: budget.loading ? null : _showSetMonthlyIncomeDialog,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text('أنواع وحدود المصروفات — الشهر الحالي',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              IconButton.filledTonal(
                tooltip: 'إضافة نوع مصروف',
                onPressed: budget.loading ? null : _showAddCategoryDialog,
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!canManageBudgets)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                    'يمكنك إضافة نوع جديد، لكن تعديل حدود الأنواع الموجودة يحتاج صلاحية إدارة الميزانيات.'),
              ),
            ),
          ...categories.map((cat) {
            final current = budget.budgets
                .where((b) => _categoryKey(b.category) == _categoryKey(cat))
                .firstOrNull;
            final spent =
                current?.spent ?? _categorySpent(budget.categoryTotals, cat);
            final limit = current?.limit ?? 0;
            final remaining = limit - spent;
            final percent =
                limit > 0 ? (spent / limit).clamp(0.0, 1.0).toDouble() : 0.0;
            final remainingText = remaining >= 0
                ? 'المتبقي ${remaining.toStringAsFixed(0)} ج'
                : 'تجاوزت الحد بـ ${remaining.abs().toStringAsFixed(0)} ج';
            return Card(
              child: ListTile(
                leading: Text(AppConstants.categoryIcons[cat] ?? '📌',
                    style: const TextStyle(fontSize: 24)),
                title: Text(cat),
                subtitle: limit > 0
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              'الحد ${limit.toStringAsFixed(0)} ج — المصروف هذا الشهر ${spent.toStringAsFixed(0)} ج'),
                          Text(
                            remainingText,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: remaining < 0
                                  ? AppTheme.expenseRed
                                  : AppTheme.incomeGreen,
                            ),
                          ),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                            value: percent,
                            color: percent > .85
                                ? AppTheme.expenseRed
                                : AppTheme.accentTeal,
                          ),
                        ],
                      )
                    : Text(
                        'لا يوجد حد محدد — المصروف هذا الشهر ${spent.toStringAsFixed(0)} ج'),
                trailing: TextButton(
                  onPressed: canManageBudgets && !budget.loading
                      ? () => _showSetBudgetDialog(cat)
                      : null,
                  child: const Text('تحديد حد'),
                ),
              ),
            );
          }),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _resetThisDevice,
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Reset this device / إعادة ضبط هذا الجهاز'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryGreen,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                await auth.signOut();
                if (context.mounted) {
                  Navigator.pushNamedAndRemoveUntil(
                      context, '/auth', (_) => false);
                }
              },
              icon: const Icon(Icons.logout_rounded),
              label: const Text('تسجيل الخروج'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.expenseRed,
                side: const BorderSide(color: AppTheme.expenseRed),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text('Budget Home v${AppConstants.appVersion}',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  double _categorySpent(Map<String, double> totals, String category) {
    final key = _categoryKey(category);
    for (final entry in totals.entries) {
      if (_categoryKey(entry.key) == key) return entry.value;
    }
    return 0;
  }

  String _categoryKey(String value) => CategoryUtils.key(value);
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
