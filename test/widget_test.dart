import 'package:flutter_test/flutter_test.dart';

import 'package:budget_home/main.dart';

void main() {
  testWidgets('Budget Home app starts on splash screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BudgetHomeApp());

    expect(find.text('Budget Home'), findsOneWidget);
  });
}
