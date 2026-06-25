import 'package:flutter_test/flutter_test.dart';
import 'package:budget_home/models/team_model.dart';
import 'package:budget_home/models/transaction_model.dart';

void main() {
  test('TeamModel identifies members and managers', () {
    final team = TeamModel(
      id: 'cars',
      groupId: 'family',
      name: 'السيارات',
      ownerId: 'admin',
      ownerName: 'كمال',
      memberIds: const ['admin', 'driver'],
    );

    expect(team.hasMember('driver'), isTrue);
    expect(team.hasMember('other'), isFalse);
    expect(team.canManage('admin'), isTrue);
    expect(team.canManage('other', isAdmin: true), isTrue);
  });

  test('TeamModel stores balance and falls back from old limit field', () {
    final team = TeamModel(
      id: 'cars',
      groupId: 'family',
      name: 'السيارات',
      ownerId: 'admin',
      ownerName: 'كمال',
      balance: 1000,
    );
    final legacy = TeamModel.fromMap({
      'id': 'old-cars',
      'groupId': 'family',
      'name': 'السيارات القديمة',
      'ownerId': 'admin',
      'ownerName': 'كمال',
      'limit': 750,
    });

    expect(team.toMap()['balance'], 1000);
    expect(legacy.balance, 750);
  });

  test('TransactionModel keeps team expense metadata optional', () {
    final teamTxn = TransactionModel(
      id: 't1',
      groupId: 'family',
      userId: 'driver',
      userName: 'ميرو',
      amount: 100,
      category: 'بنزين',
      isExpense: true,
      teamId: 'cars',
      teamName: 'السيارات',
    );
    final familyTxn = TransactionModel(
      id: 't2',
      groupId: 'family',
      userId: 'admin',
      userName: 'كمال',
      amount: 200,
      category: 'خضار',
      isExpense: true,
    );

    expect(teamTxn.isTeamExpense, isTrue);
    expect(TransactionModel.fromMap(teamTxn.toMap()).teamName, 'السيارات');
    expect(familyTxn.isTeamExpense, isFalse);
  });
}
