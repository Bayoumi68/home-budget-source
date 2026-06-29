class UserModel {
  final String id;
  final String name;
  final String? phone;
  final String? authUid;
  final String? photoUrl;
  final bool isAdmin;
  final double monthlyLimit;
  final double currentSpending;
  final bool canAddExpenses;
  final bool canViewReports;
  final bool canManageMembers;
  final bool canManageBudgets;
  final bool phoneVerified;
  final String? email;
  // Non-empty = this person is a WORKER belonging to that team, NOT a family
  // member. Workers are kept out of family lists/privacy; only the admin sees
  // them (under الفرق), and they log in to a team-only view of their own data.
  final String? teamId;
  final DateTime createdAt;

  UserModel({
    required this.id,
    required this.name,
    this.phone,
    this.authUid,
    this.photoUrl,
    this.isAdmin = false,
    this.monthlyLimit = 0,
    this.currentSpending = 0,
    bool? canAddExpenses,
    bool? canViewReports,
    bool? canManageMembers,
    bool? canManageBudgets,
    this.phoneVerified = false,
    this.email,
    this.teamId,
    DateTime? createdAt,
  })  : canAddExpenses = canAddExpenses ?? true,
        canViewReports = canViewReports ?? true,
        canManageMembers = canManageMembers ?? isAdmin,
        canManageBudgets = canManageBudgets ?? isAdmin,
        createdAt = createdAt ?? DateTime.now();

  /// A member is "joined" once a real login (Google/email) is bound to them.
  /// Admin-pre-registered members are pending until then.
  bool get joined => authUid != null && authUid!.isNotEmpty;

  /// A worker belongs to a team and is not part of the family proper.
  bool get isWorker => (teamId ?? '').trim().isNotEmpty;

  String get roleName => isAdmin ? 'قائد العائلة' : 'عضو';
  bool get hasSpendingLimit => monthlyLimit > 0;
  double get remainingLimit =>
      hasSpendingLimit ? monthlyLimit - currentSpending : double.infinity;
  double get spendingPercentage => monthlyLimit > 0
      ? (currentSpending / monthlyLimit).clamp(0.0, 1.0).toDouble()
      : 0;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'phone': phone,
        'authUid': authUid,
        'photoUrl': photoUrl,
        'isAdmin': isAdmin,
        'monthlyLimit': monthlyLimit,
        'currentSpending': currentSpending,
        'canAddExpenses': canAddExpenses,
        'canViewReports': canViewReports,
        'canManageMembers': canManageMembers,
        'canManageBudgets': canManageBudgets,
        'phoneVerified': phoneVerified,
        'email': email,
        'teamId': teamId,
        'createdAt': createdAt.toIso8601String(),
      };

  factory UserModel.fromMap(Map<String, dynamic> map) {
    final isAdmin = map['isAdmin'] ?? false;
    return UserModel(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      phone: map['phone'],
      authUid: map['authUid'],
      photoUrl: map['photoUrl'],
      isAdmin: isAdmin,
      monthlyLimit: (map['monthlyLimit'] as num?)?.toDouble() ?? 0,
      currentSpending: (map['currentSpending'] as num?)?.toDouble() ?? 0,
      canAddExpenses: map['canAddExpenses'] ?? true,
      canViewReports: map['canViewReports'] ?? true,
      canManageMembers: map['canManageMembers'] ?? isAdmin,
      canManageBudgets: map['canManageBudgets'] ?? isAdmin,
      phoneVerified: map['phoneVerified'] ?? false,
      email: map['email'],
      teamId: map['teamId'],
      createdAt: DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
    );
  }

  UserModel copyWith({
    String? id,
    String? name,
    String? phone,
    String? authUid,
    String? photoUrl,
    bool? isAdmin,
    double? monthlyLimit,
    double? currentSpending,
    bool? canAddExpenses,
    bool? canViewReports,
    bool? canManageMembers,
    bool? canManageBudgets,
    bool? phoneVerified,
    String? email,
    String? teamId,
    DateTime? createdAt,
  }) =>
      UserModel(
        id: id ?? this.id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        authUid: authUid ?? this.authUid,
        photoUrl: photoUrl ?? this.photoUrl,
        isAdmin: isAdmin ?? this.isAdmin,
        monthlyLimit: monthlyLimit ?? this.monthlyLimit,
        currentSpending: currentSpending ?? this.currentSpending,
        canAddExpenses: canAddExpenses ?? this.canAddExpenses,
        canViewReports: canViewReports ?? this.canViewReports,
        canManageMembers: canManageMembers ?? this.canManageMembers,
        canManageBudgets: canManageBudgets ?? this.canManageBudgets,
        phoneVerified: phoneVerified ?? this.phoneVerified,
        email: email ?? this.email,
        teamId: teamId ?? this.teamId,
        createdAt: createdAt ?? this.createdAt,
      );
}
