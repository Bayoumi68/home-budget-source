import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../models/category_model.dart';
import '../providers/budget_provider.dart';
import '../services/database_service.dart';

/// Admin review of what the parser has LEARNED: each word it now maps to an
/// expense category (taught when an admin corrects a category). Wrong ones can
/// be deleted here. This is only the learned categories — the action verbs
/// (إضافة/حول/اسحب/…) are fixed in code, not learned.
class LearnedKeywordsScreen extends StatefulWidget {
  final String groupId;
  const LearnedKeywordsScreen({super.key, required this.groupId});

  @override
  State<LearnedKeywordsScreen> createState() => _LearnedKeywordsScreenState();
}

class _LearnedKeywordsScreenState extends State<LearnedKeywordsScreen> {
  final _db = DatabaseService();
  List<Map<String, String>> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await _db.getLearnedKeywordEntries(widget.groupId);
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  Future<void> _delete(Map<String, String> e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف كلمة متعلَّمة'),
        content: Text(
            'حذف الربط: "${e['keyword']}" → ${e['category']}؟\nلن يؤثر على المصاريف المسجّلة، فقط على التصنيف التلقائي مستقبلًا.'),
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
    if (ok != true) return;
    await _db.deleteLearnedKeyword(widget.groupId, e['id']!);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final categories = context.watch<BudgetProvider>().categories;
    return Scaffold(
      appBar: AppBar(title: const Text('الكلمات المتعلَّمة')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'لم يتعلّم التطبيق أي كلمات بعد.\nكلما صحّحت نوع مصروف، يتعلّم الكلمة هنا.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final e = _items[i];
                      final icon = categories.iconFor(e['category'] ?? '');
                      return ListTile(
                        leading: Text(icon,
                            style: const TextStyle(fontSize: 22)),
                        title: Text(e['keyword'] ?? ''),
                        subtitle: Text('النوع: ${e['category']}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded,
                              color: AppTheme.expenseRed),
                          tooltip: 'حذف',
                          onPressed: () => _delete(e),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
