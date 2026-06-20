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
      final items = AIService.parseExpenseMessages(
        'دفعت 250 جنيه سوبر ماركت',
      );

      expect(items, hasLength(1));
      expect(items.first['amount'], 250);
      expect(items.first['category'], 'سوبر ماركت');
    });

    test('parses category before amount with attached preposition', () {
      final items = AIService.parseExpenseMessages(
        'خضار ب100 وكهرباء 200',
      );

      expect(items, hasLength(2));
      expect(items[0]['amount'], 100);
      expect(items[0]['category'], 'خضار');
      expect(items[1]['amount'], 200);
      expect(items[1]['category'], 'كهرباء');
    });

    test('parses mixed category-before and amount-before expense order', () {
      final items = AIService.parseExpenseMessages(
        'اشتريت خضار بـ100 جنيه و200 جنيه كهرباء',
      );

      expect(items, hasLength(2));
      expect(items[0]['amount'], 100);
      expect(items[0]['category'], 'خضار');
      expect(items[1]['amount'], 200);
      expect(items[1]['category'], 'كهرباء');
    });

    test('formats expense text in readable Arabic', () {
      final item = AIService.parseExpenseMessages('صرفت 200 كهرباء').single;

      expect(AIService.formatExpenseText(item), 'مصروف 200 ج - كهرباء');
    });

    test('classifies Egyptian service words into built-in categories', () {
      expect(
        AIService.parseExpenseMessages('انا دفعت 100 اوبر').single['category'],
        'مواصلات',
      );
      expect(
        AIService.parseExpenseMessages(
                'انا دفعت 100 جنيه جبت ادويه من الصيدليه')
            .single['category'],
        'صحة',
      );
      expect(
        AIService.parseExpenseMessages('دفعت 100 درس هنا').single['category'],
        'تعليم',
      );
      expect(
        AIService.parseExpenseMessages('دفعت 60 توك توك').single['category'],
        'مواصلات',
      );
      expect(
        AIService.parseExpenseMessages('دفعت 400 روشتة وتحاليل')
            .single['category'],
        'صحة',
      );
      expect(
        AIService.parseExpenseMessages('دفعت 250 حضانة').single['category'],
        'تعليم',
      );
      expect(
        AIService.parseExpenseMessages('اشتريت 180 مسحوق غسيل وكلور')
            .single['category'],
        'منظفات',
      );
      expect(
        AIService.parseExpenseMessages('دفعت 350 للسباك وتصليح الحنفية')
            .single['category'],
        'صيانة',
      );
      expect(
        AIService.parseExpenseMessages('دفعت 120 رسوم رخصة').single['category'],
        'رسوم وخدمات',
      );
    });
  });
}
