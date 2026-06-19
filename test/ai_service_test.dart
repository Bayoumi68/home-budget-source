import 'package:flutter_test/flutter_test.dart';
import 'package:budget_home/services/ai_service.dart';

void main() {
  group('AIService.parseExpenseMessages', () {
    test('parses multiple Arabic expense items with Arabic separators', () {
      final items = AIService.parseExpenseMessages(
        'دفعت 100 جنيه خضار و200 جنيه كهرباء و300 جنيه ايجار',
      );

      expect(items, hasLength(3));
      expect(items[0]['amount'], 100);
      expect(items[0]['category'], 'خضار');
      expect(items[1]['amount'], 200);
      expect(items[1]['category'], 'كهرباء');
      expect(items[2]['amount'], 300);
      expect(items[2]['category'], 'إيجار');
    });

    test('parses multiple expenses without currency words', () {
      final items = AIService.parseExpenseMessages(
        'دفعت 100 خضار و200 كهرباء',
      );

      expect(items, hasLength(2));
      expect(items[0]['amount'], 100);
      expect(items[0]['category'], 'خضار');
      expect(items[1]['amount'], 200);
      expect(items[1]['category'], 'كهرباء');
    });

    test('parses Arabic digits and natural separators', () {
      final items = AIService.parseExpenseMessages(
        'صرفت ٥٠ مياه، ثم ٧٥ عيش كمان ١٢٠ فراخ',
      );

      expect(items, hasLength(3));
      expect(items[0]['amount'], 50);
      expect(items[0]['category'], 'مياه');
      expect(items[1]['amount'], 75);
      expect(items[1]['category'], 'عيش');
      expect(items[2]['amount'], 120);
      expect(items[2]['category'], 'فراخ');
    });

    test('keeps single expense behavior as one parsed item', () {
      final items = AIService.parseExpenseMessages('دفعت 250 جنيه سوبر ماركت');

      expect(items, hasLength(1));
      expect(items.first['amount'], 250);
      expect(items.first['category'], 'أكل ومشروبات');
    });
  });
}
