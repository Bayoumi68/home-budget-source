import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../config/theme.dart';
import '../config/constants.dart';
import '../models/wallet_model.dart';
import '../models/wallet_entry_model.dart';
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

  // Cache each wallet's ledger future so rebuilds don't refetch (which caused
  // the flicker). Keyed by wallet + its last-updated stamp, so it only reloads
  // when that wallet actually changed.
  final Map<String, Future<List<WalletEntryModel>>> _entryFutures = {};

  // Explicit, deterministic expand/collapse state (no nested ExpansionTiles).
  final Set<String> _collapsedGroups = {};
  final Set<String> _expandedWallets = {};

  Future<List<WalletEntryModel>> _entriesFor(WalletModel w) {
    final key = '${w.id}|${w.updatedAt?.toIso8601String() ?? ''}|${w.balance}';
    return _entryFutures.putIfAbsent(
        key, () => _db.getWalletEntriesSync(widget.groupId, w.id));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Ensure every member has a wallet so the admin can fund them here.
      await _db.provisionMemberWallets(widget.groupId);
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
    var period = current?.period ?? 'monthly';
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('حد الميزانية — $category'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                textDirection: ui.TextDirection.ltr,
                decoration: const InputDecoration(
                  hintText: 'المبلغ بالجنيه',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'daily', label: Text('يومي')),
                  ButtonSegment(value: 'weekly', label: Text('أسبوعي')),
                  ButtonSegment(value: 'monthly', label: Text('شهري')),
                ],
                selected: {period},
                onSelectionChanged: (values) {
                  setDialogState(() => period = values.first);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, {
                'amount': double.tryParse(controller.text.trim()),
                'period': period,
              }),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    final amount = result?['amount'] as double?;
    final selectedPeriod = (result?['period'] as String?) ?? 'monthly';
    if (amount != null && amount >= 0) {
      if (mounted) {
        await context.read<BudgetProvider>().setBudget(
              widget.groupId,
              category,
              amount,
              period: selectedPeriod,
            );
      }
    }
  }

  Future<void> _showAddWalletDialog() async {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final balanceController = TextEditingController();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة محفظة'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                textDirection: ui.TextDirection.rtl,
                decoration: const InputDecoration(
                  labelText: 'اسم المحفظة',
                  hintText: 'مثال: كاش، بنك، فودافون كاش',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                textDirection: ui.TextDirection.rtl,
                decoration: const InputDecoration(
                  labelText: 'الوصف (اختياري)',
                  hintText: 'مثال: حساب البنك الأهلي',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: balanceController,
                keyboardType: TextInputType.number,
                textDirection: ui.TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'الرصيد الافتتاحي',
                  hintText: 'المبلغ بالجنيه',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
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
              {
                'name': nameController.text.trim(),
                'description': descController.text.trim(),
                'balance': double.tryParse(
                      balanceController.text.trim().replaceAll(',', '.'),
                    ) ??
                    0,
              },
            ),
            child: const Text('إضافة'),
          ),
        ],
      ),
    );
    nameController.dispose();
    descController.dispose();
    balanceController.dispose();
    if (result == null || !mounted) return;
    final name = (result['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) return;
    final user = context.read<AuthProvider>().user;
    await context.read<BudgetProvider>().addWallet(
          widget.groupId,
          name,
          description: result['description'] as String? ?? '',
          balance: result['balance'] as double? ?? 0,
          byName: user?.name,
          byPhone: user?.phone,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تمت إضافة محفظة $name')),
    );
  }

  Future<void> _showEditWalletDialog(WalletModel wallet) async {
    final nameController = TextEditingController(text: wallet.name);
    final descController = TextEditingController(text: wallet.description);
    final limitController = TextEditingController(
        text: wallet.limit > 0 ? wallet.limit.toStringAsFixed(0) : '');
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تعديل ${wallet.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                textDirection: ui.TextDirection.rtl,
                decoration: const InputDecoration(
                  labelText: 'اسم المحفظة',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                textDirection: ui.TextDirection.rtl,
                decoration: const InputDecoration(
                  labelText: 'الوصف (اختياري)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: limitController,
                keyboardType: TextInputType.number,
                textDirection: ui.TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'الحد/الميزانية (اختياري)',
                  hintText: 'مبلغ إرشادي — ليس الرصيد',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'الحد دليل إرشادي فقط، لا يغيّر الرصيد. الرصيد يتغير بالحركات فقط.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {
              'name': nameController.text.trim(),
              'description': descController.text.trim(),
              'limit': limitController.text.trim(),
            }),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    nameController.dispose();
    descController.dispose();
    limitController.dispose();
    if (result == null || !mounted) return;
    final user = context.read<AuthProvider>().user;
    await context.read<BudgetProvider>().updateWallet(
          widget.groupId,
          wallet.id,
          name: result['name'],
          description: result['description'],
          limit: double.tryParse(
                  (result['limit'] ?? '').replaceAll(',', '.')) ??
              0,
          byName: user?.name,
          byPhone: user?.phone,
        );
  }

  /// Record an external cash deposit/withdrawal on a wallet (a new ledger
  /// entry). The balance is never set directly — it moves only via such records.
  Future<void> _showCashDialog(WalletModel wallet,
      {required bool withdraw}) async {
    final controller = TextEditingController();
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(withdraw
            ? 'سحب نقدي من ${wallet.name}'
            : 'إيداع نقدي في ${wallet.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              textDirection: ui.TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'المبلغ',
                hintText: 'المبلغ بالجنيه',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              withdraw
                  ? 'يُسجَّل كحركة سحب في كشف المحفظة.'
                  : 'يُسجَّل كحركة إيداع في كشف المحفظة.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              double.tryParse(controller.text.trim().replaceAll(',', '.')),
            ),
            child: Text(withdraw ? 'سحب' : 'إيداع'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (amount == null || amount <= 0 || !mounted) return;
    final user = context.read<AuthProvider>().user;
    final error = await context.read<BudgetProvider>().walletCashMovement(
          widget.groupId,
          wallet.id,
          amount,
          deposit: !withdraw,
          byName: user?.name,
          byPhone: user?.phone,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ??
          (withdraw
              ? 'تم سحب ${amount.toStringAsFixed(0)} ج من ${wallet.name}'
              : 'تم إيداع ${amount.toStringAsFixed(0)} ج في ${wallet.name}')),
    ));
  }

  Future<void> _confirmDeleteWallet(WalletModel wallet) async {
    if (wallet.isDefault) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يمكن حذف المحفظة الأساسية.')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('حذف ${wallet.name}؟'),
        content: const Text(
            'لا يمكن حذف محفظة بها رصيد — اسحب رصيدها أولًا. سيتم إخفاء المحفظة مع الاحتفاظ بسجل حركتها.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final error =
        await context.read<BudgetProvider>().deleteWallet(widget.groupId, wallet.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'تم حذف محفظة ${wallet.name}')),
    );
  }

  /// Admin funds (or withdraws from) a member's wallet via a transfer to/from
  /// one of the admin's cash wallets.
  Future<void> _showFundDialog(WalletModel memberWallet,
      {required bool withdraw}) async {
    final adminWallets =
        context.read<BudgetProvider>().wallets.where((w) => w.isAdminWallet).toList();
    if (adminWallets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف محفظة نقدية لك أولًا.')),
      );
      return;
    }
    var source = adminWallets.first;
    final amountController = TextEditingController();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(withdraw
              ? 'سحب من ${memberWallet.name}'
              : 'تمويل ${memberWallet.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<WalletModel>(
                initialValue: source,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: withdraw ? 'إلى محفظتي' : 'من محفظتي',
                  border: const OutlineInputBorder(),
                ),
                items: adminWallets
                    .map((w) => DropdownMenuItem(
                          value: w,
                          child: Text(
                              '${w.name} (${w.balance.toStringAsFixed(0)} ج)'),
                        ))
                    .toList(),
                onChanged: (v) => setDialog(() => source = v ?? source),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                textDirection: ui.TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'المبلغ',
                  hintText: 'المبلغ بالجنيه',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                'source': source,
                'amount': double.tryParse(
                    amountController.text.trim().replaceAll(',', '.')),
              }),
              child: Text(withdraw ? 'سحب' : 'تمويل'),
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    if (result == null || !mounted) return;
    final amount = result['amount'] as double?;
    final src = result['source'] as WalletModel;
    if (amount == null || amount <= 0) return;
    final user = context.read<AuthProvider>().user;
    final error = await context.read<BudgetProvider>().transfer(
          widget.groupId,
          fromWalletId: withdraw ? memberWallet.id : src.id,
          toWalletId: withdraw ? src.id : memberWallet.id,
          amount: amount,
          byName: user?.name,
          byPhone: user?.phone,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ??
          (withdraw
              ? 'تم سحب ${amount.toStringAsFixed(0)} ج من ${memberWallet.name}'
              : 'تم تمويل ${memberWallet.name} بـ ${amount.toStringAsFixed(0)} ج')),
    ));
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

  Future<void> _removeCategory(String category) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('إزالة $category؟'),
        content: const Text(
          'سيختفي هذا النوع من الاختيارات والقاموس، وسيتم حذف حده الشهري فقط. المصروفات القديمة ستظل محفوظة في السجلات.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إزالة')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final budgetProvider = context.read<BudgetProvider>();
    await budgetProvider.removeExpenseCategory(widget.groupId, category);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تمت إزالة نوع المصروف: $category')),
    );
  }

  Future<void> _shareInviteOnWhatsApp() async {
    final groupId = context.read<AuthProvider>().group?.id ?? widget.groupId;
    final code = await _db.createInvite(groupId: groupId);
    if (!mounted) return;
    final inviteLanding =
        '${AppConstants.appWebLink}/install.html?invite=$code&groupId=$groupId&v=${Uri.encodeComponent(AppConstants.appVersion)}';
    final message = 'دعوة للانضمام إلى عائلتنا على Home Budget\n\n'
        'افتح الرابط التالي وادخل اسمك للانضمام:\n$inviteLanding\n\n'
        'هذا الرابط للاستخدام مرة واحدة فقط (كود: $code).\n'
        'افتح نسخة الويب مباشرة على أندرويد أو آيفون بدون تثبيت.\n\n'
        'رابط APK الاختياري لأندرويد:\n${AppConstants.androidDownloadLink}';
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
    final message = 'جرّب Home Budget وأنشئ عائلتك أنت\n\n'
        'افتح الرابط التالي:\n$trialUrl\n\n'
        'افتح نسخة الويب مباشرة على أندرويد أو آيفون بدون تثبيت.\n'
        'APK اختياري لأندرويد فقط لو تريد تطبيق مثبت أو صوت أفضل.\n\n'
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
                  leading: const Icon(Icons.share_rounded,
                      color: AppTheme.incomeGreen),
                  title: const Text('دعوة فرد للعائلة'),
                  subtitle: const Text(
                      'ينشئ رابط دعوة لمرة واحدة — يدخل اسمه وينضم.'),
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
          _buildWalletsSection(context, auth, budget),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text('أنواع وحدود المصروفات',
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
            final periodLabel = current?.periodLabel ?? 'شهري';
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
                              'حد $periodLabel ${limit.toStringAsFixed(0)} ج — المصروف في نفس الفترة ${spent.toStringAsFixed(0)} ج'),
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
                        'لا يوجد حد محدد — مصروف الشهر ${spent.toStringAsFixed(0)} ج'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'إزالة النوع',
                      onPressed:
                          budget.loading ? null : () => _removeCategory(cat),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                    TextButton(
                      onPressed: canManageBudgets && !budget.loading
                          ? () => _showSetBudgetDialog(cat)
                          : null,
                      child: const Text('تحديد حد'),
                    ),
                  ],
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
          const Center(
            child: Text('Home Budget v${AppConstants.appVersion}',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ─── Wallets section (role-aware: admin manages cash + funds members) ───
  Widget _buildWalletsSection(
      BuildContext context, AuthProvider auth, BudgetProvider budget) {
    final user = auth.user;
    final isAdmin = user?.isAdmin == true;

    // A member sees only their own wallet (tap the line to view its ledger).
    if (!isAdmin) {
      final mine = budget.wallets
          .where((w) => w.isMemberWallet && w.ownerId == user?.id)
          .toList();
      return _walletsGroupCard(
        context,
        budget,
        title: 'محفظتي',
        subtitle: 'اضغط لعرض الرصيد والحركة — يموّلها قائد العائلة.',
        wallets: mine,
        emptyText: 'جاري تجهيز محفظتك...',
      );
    }

    final adminWallets = budget.wallets.where((w) => w.isAdminWallet).toList();
    final memberWallets = budget.wallets.where((w) => w.isMemberWallet).toList();
    return Column(
      children: [
        _walletsGroupCard(
          context,
          budget,
          title: 'محافظي (مصادر النقد)',
          subtitle: 'كاش/بنك — اضغط + لإضافة محفظة، واضغط محفظة لإدارتها.',
          wallets: adminWallets,
          onAdd: budget.loading ? null : _showAddWalletDialog,
          showManage: true,
        ),
        const SizedBox(height: 12),
        _walletsGroupCard(
          context,
          budget,
          title: 'محافظ الأعضاء',
          subtitle: 'اضغط على عضو ثم موّل أو اسحب.',
          wallets: memberWallets,
          showFunding: true,
          emptyText: 'لا يوجد أعضاء بعد. أضف أفراد العائلة من شاشة الأعضاء.',
        ),
      ],
    );
  }

  Widget _walletsGroupCard(
    BuildContext context,
    BudgetProvider budget, {
    required String title,
    required String subtitle,
    required List<WalletModel> wallets,
    VoidCallback? onAdd,
    bool showManage = false,
    bool showFunding = false,
    String emptyText = 'لا توجد محافظ بعد.',
  }) {
    final collapsed = _collapsedGroups.contains(title);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() {
              if (collapsed) {
                _collapsedGroups.remove(title);
              } else {
                _collapsedGroups.add(title);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_wallet_rounded,
                      color: AppTheme.incomeGreen),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        Text(subtitle,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                  if (onAdd != null)
                    IconButton(
                      tooltip: 'إضافة محفظة',
                      icon: const Icon(Icons.add_rounded),
                      onPressed: onAdd,
                    ),
                  Icon(collapsed
                      ? Icons.expand_more_rounded
                      : Icons.expand_less_rounded),
                ],
              ),
            ),
          ),
          if (!collapsed) ...[
            const Divider(height: 1),
            if (wallets.isEmpty)
              Padding(padding: const EdgeInsets.all(12), child: Text(emptyText))
            else
              ...wallets.map((w) => _walletLine(context, budget, w,
                  showManage: showManage, showFunding: showFunding)),
          ],
        ],
      ),
    );
  }

  Widget _walletLine(BuildContext context, BudgetProvider budget, WalletModel w,
      {bool showManage = false, bool showFunding = false}) {
    final fmt = NumberFormat('#,##0');
    final hasButtons = showManage || showFunding;
    final expanded = _expandedWallets.contains(w.id);
    // Spending this month from this wallet, vs its guide limit (red flag only).
    final spent = budget.transactions
        .where((t) =>
            t.isExpense &&
            t.walletId == w.id &&
            CategoryUtils.isThisMonth(t.date))
        .fold<double>(0, (s, t) => s + t.amount);
    final overLimit = w.limit > 0 && spent > w.limit + 0.005;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (expanded) {
              _expandedWallets.remove(w.id);
            } else {
              _expandedWallets.add(w.id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Icon(
                  w.isMemberWallet
                      ? Icons.person_rounded
                      : (w.isDefault
                          ? Icons.account_balance_wallet_rounded
                          : Icons.wallet_rounded),
                  color: overLimit ? AppTheme.expenseRed : AppTheme.gold,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(w.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        'الرصيد: ${fmt.format(w.balance)} ج'
                        '${w.description.isEmpty ? '' : ' — ${w.description}'}',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      if (w.limit > 0)
                        Text(
                          'الحد: ${fmt.format(w.limit)} ج — صرف الشهر ${fmt.format(spent)} ج'
                          '${overLimit ? ' ⚠ تجاوز الحد' : ''}',
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                overLimit ? AppTheme.expenseRed : Colors.grey,
                            fontWeight: overLimit
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasButtons)
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
              if (showManage) ...[
                OutlinedButton.icon(
                  onPressed: budget.loading
                      ? null
                      : () => _showCashDialog(w, withdraw: false),
                  icon: const Icon(Icons.add_card_rounded, size: 18),
                  label: const Text('إيداع'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.incomeGreen),
                ),
                OutlinedButton.icon(
                  onPressed: budget.loading
                      ? null
                      : () => _showCashDialog(w, withdraw: true),
                  icon: const Icon(Icons.output_rounded, size: 18),
                  label: const Text('سحب'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.expenseRed),
                ),
                OutlinedButton.icon(
                  onPressed:
                      budget.loading ? null : () => _showEditWalletDialog(w),
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: const Text('تعديل'),
                ),
                OutlinedButton.icon(
                  onPressed: (budget.loading || w.isDefault)
                      ? null
                      : () => _confirmDeleteWallet(w),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('حذف'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.expenseRed),
                ),
              ],
              if (showFunding) ...[
                OutlinedButton.icon(
                  onPressed: budget.loading
                      ? null
                      : () => _showFundDialog(w, withdraw: false),
                  icon: const Icon(Icons.add_card_rounded, size: 18),
                  label: const Text('تمويل'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.incomeGreen),
                ),
                OutlinedButton.icon(
                  onPressed: budget.loading
                      ? null
                      : () => _showFundDialog(w, withdraw: true),
                  icon: const Icon(Icons.output_rounded, size: 18),
                  label: const Text('سحب'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.expenseRed),
                ),
              ],
            ],
          ),
        if (hasButtons) const SizedBox(height: 8),
        FutureBuilder<List<WalletEntryModel>>(
          future: _entriesFor(w),
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: LinearProgressIndicator(minHeight: 2),
              );
            }
            final entries =
                (snap.data ?? const <WalletEntryModel>[]).reversed.toList();
            if (entries.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Text('لا توجد حركات بعد على هذه المحفظة.'),
              );
            }
            final dt = DateFormat('yyyy/MM/dd HH:mm');
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 18,
                headingRowHeight: 34,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 56,
                columns: const [
                  DataColumn(label: Text('التاريخ')),
                  DataColumn(label: Text('البيان')),
                  DataColumn(label: Text('وارد')),
                  DataColumn(label: Text('منصرف')),
                  DataColumn(label: Text('الرصيد')),
                  DataColumn(label: Text('بواسطة')),
                ],
                rows: entries
                    .map(
                      (e) => DataRow(cells: [
                        DataCell(Text(dt.format(e.at))),
                        DataCell(Text(_entryStatement(e))),
                        DataCell(Text(
                          e.isDebit ? fmt.format(e.amount) : '—',
                          style: const TextStyle(color: AppTheme.incomeGreen),
                        )),
                        DataCell(Text(
                          !e.isDebit ? fmt.format(e.amount) : '—',
                          style: const TextStyle(color: AppTheme.expenseRed),
                        )),
                        DataCell(Text(fmt.format(e.balanceAfter))),
                        DataCell(Text(e.byLabel)),
                      ]),
                    )
                    .toList(),
              ),
            );
          },
                ),
              ],
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }

  String _entryStatement(WalletEntryModel e) {
    final note = (e.note ?? '').trim();
    if (note.isNotEmpty) return note;
    switch (e.source) {
      case 'opening':
        return 'رصيد افتتاحي';
      case 'injection':
        return 'إيداع نقدي';
      case 'withdrawal':
        return 'سحب نقدي';
      case 'expense':
        return 'مصروف';
      case 'adjustment':
        return 'تعديل رصيد';
      case 'reversal':
        return 'إرجاع';
      case 'transfer':
        return 'تحويل';
      default:
        return e.source;
    }
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
