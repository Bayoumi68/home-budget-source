/// A family's expense or income category — the single dynamic source of truth
/// for the category list, its icon, and its keyword-based auto-detection hints.
/// Replaces the old hardcoded AppConstants/AIService tables.
class CategoryModel {
  final String id;
  final String name;
  final String icon;
  final List<String> keywords;
  final bool isIncome;
  final bool hidden;
  // True for the 19 categories seeded at family creation (still editable).
  final bool isBuiltIn;
  final DateTime createdAt;
  final DateTime? updatedAt;

  CategoryModel({
    required this.id,
    required this.name,
    this.icon = '📌',
    this.keywords = const [],
    this.isIncome = false,
    this.hidden = false,
    this.isBuiltIn = false,
    DateTime? createdAt,
    this.updatedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'icon': icon,
        'keywords': keywords,
        'isIncome': isIncome,
        'hidden': hidden,
        'isBuiltIn': isBuiltIn,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  factory CategoryModel.fromMap(Map<String, dynamic> map) => CategoryModel(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        icon: (map['icon'] ?? '📌').toString(),
        keywords: (map['keywords'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        isIncome: map['isIncome'] == true,
        hidden: map['hidden'] == true,
        isBuiltIn: map['isBuiltIn'] == true,
        createdAt: DateTime.tryParse((map['createdAt'] ?? '').toString()) ??
            DateTime.now(),
        updatedAt: map['updatedAt'] == null
            ? null
            : DateTime.tryParse(map['updatedAt'].toString()),
      );

  CategoryModel copyWith({
    String? name,
    String? icon,
    List<String>? keywords,
    bool? isIncome,
    bool? hidden,
    bool? isBuiltIn,
    DateTime? updatedAt,
  }) =>
      CategoryModel(
        id: id,
        name: name ?? this.name,
        icon: icon ?? this.icon,
        keywords: keywords ?? this.keywords,
        isIncome: isIncome ?? this.isIncome,
        hidden: hidden ?? this.hidden,
        isBuiltIn: isBuiltIn ?? this.isBuiltIn,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

extension CategoryListLookup on List<CategoryModel> {
  /// The icon for the category matching [name] (case/diacritic-insensitive),
  /// or a generic pin if not found — the single icon lookup used everywhere,
  /// replacing the old hardcoded AppConstants.categoryIcons map.
  String iconFor(String name) {
    for (final c in this) {
      if (c.name == name) return c.icon;
    }
    return '📌';
  }
}
