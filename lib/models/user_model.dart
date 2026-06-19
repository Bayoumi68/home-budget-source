class UserModel {
  final String id;
  final String name;
  final String? phone;
  final String? photoUrl;
  final bool isAdmin;
  final double monthlyLimit;
  final double currentSpending;
  final bool canAddExpenses;
  final bool canViewReports;
  final bool canManageMembers;
  final bool canManageBudgets;
  final DateTime createdAt;

  UserModel({
    required this.id,
    required this.name,
    this.phone,
    this.photoUrl,
    this.isAdmin = false,
    this.monthlyLimit = 0,
    this.currentSpending = 0,
    bool? canAddExpenses,
    bool? canViewReports,
    bool? canManageMembers,
    bool? canManageBudgets,
    DateTime? createdAt,
  })  : canAddExpenses = canAddExpenses ?? true,
        canViewReports = canViewReports ?? true,
        canManageMembers = canManageMembers ?? isAdmin,
        canManageBudgets = canManageBudgets ?? isAdmin,
        createdAt = createdAt ?? DateTime.now();

  String get roleName => isAdmin ? 'قائد العائلة' : 'عضو';
  bool get hasSpendingLimit => monthlyLimit > 0;
  double get remainingLimit => hasSpendingLimit ? monthlyLimit - currentSpending : double.infinity;
  double get spendingPercentage => monthlyLimit > 0 ? (currentSpending / monthlyLimit).clamp(0.0, 1.0).toDouble() : 0;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'phone': phone,
        'photoUrl': photoUrl,
        'isAdmin': isAdmin,
        'monthlyLimit': monthlyLimit,
        'currentSpending': currentSpending,
        'canAddExpenses': canAddExpenses,
        'canViewReports': canViewReports,
        'canManageMembers': canManageMembers,
        'canManageBudgets': canManageBudgets,
        'createdAt': createdAt.toIso8601String(),
      };

  factory UserModel.fromMap(Map<String, dynamic> map) {
    final isAdmin = map['isAdmin'] ?? false;
    return UserModel(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      phone: map['phone'],
      photoUrl: map['photoUrl'],
      isAdmin: isAdmin,
      monthlyLimit: (map['monthlyLimit'] as num?)?.toDouble() ?? 0,
      currentSpending: (map['currentSpending'] as num?)?.toDouble() ?? 0,
      canAddExpenses: map['canAddExpenses'] ?? true,
      canViewReports: map['canViewReports'] ?? true,
      canManageMembers: map['canManageMembers'] ?? isAdmin,
      canManageBudgets: map['canManageBudgets'] ?? isAdmin,
      createdAt: DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
    );
  }

  UserModel copyWith({
    String? id,
    String? name,
    String? phone,
    String? photoUrl,
    bool? isAdmin,
    double? monthlyLimit,
    double? currentSpending,
    bool? canAddExpenses,
    bool? canViewReports,
    bool? canManageMembers,
    bool? canManageBudgets,
    DateTime? createdAt,
  }) =>
      UserModel(
        id: id ?? this.id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        photoUrl: photoUrl ?? this.photoUrl,
        isAdmin: isAdmin ?? this.isAdmin,
        monthlyLimit: monthlyLimit ?? this.monthlyLimit,
        currentSpending: currentSpending ?? this.currentSpending,
        canAddExpenses: canAddExpenses ?? this.canAddExpenses,
        canViewReports: canViewReports ?? this.canViewReports,
        canManageMembers: canManageMembers ?? this.canManageMembers,
        canManageBudgets: canManageBudgets ?? this.canManageBudgets,
        createdAt: createdAt ?? this.createdAt,
      );
}
