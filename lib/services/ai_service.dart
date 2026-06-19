import '../utils/category_utils.dart';

class AIService {
  // Local Arabic-first parser. It is intentionally offline: no API key, no internet.
  // Examples:
  //   "دفعت 250 جنيه سوبر ماركت" -> expense / 250 / أكل ومشروبات
  //   "سجل دخل 12000 مرتب" -> income / 12000 / راتب
  //   "بنزين ب ٣٠٠" -> expense / 300 / مواصلات

  static Map<String, dynamic>? parseExpenseMessage(String text) {
    final original = text.trim();
    if (original.isEmpty) return null;

    final normalized = _normalize(original);
    final amount = _extractAmount(normalized);
    if (amount == null || amount <= 0 || amount > 999999999) return null;

    final isIncome = _looksLikeIncome(normalized);
    final category = _detectCategory(normalized, isIncome: isIncome);

    return {
      'amount': amount,
      'category': category,
      'isExpense': !isIncome,
      'note': original,
      'confidence': _confidence(normalized, category),
    };
  }

  static List<Map<String, dynamic>> parseExpenseMessages(String text) {
    final original = text.trim();
    if (original.isEmpty) return const [];

    final normalized = _normalize(original);
    final amountMatches =
        RegExp(r'(?<!\d)(\d+(?:\.\d+)?)(?!\d)').allMatches(normalized).toList();
    if (amountMatches.length <= 1) {
      final single = parseExpenseMessage(original);
      return single == null ? const [] : [single];
    }

    final parts = <Map<String, dynamic>>[];
    for (var i = 0; i < amountMatches.length; i++) {
      final start = amountMatches[i].start;
      final end = i + 1 < amountMatches.length
          ? amountMatches[i + 1].start
          : normalized.length;
      final segment = normalized
          .substring(start, end)
          .replaceFirst(RegExp(r'^[\s،,و]+'), '')
          .replaceFirst(RegExp(r'[\s،,و]+$'), '')
          .trim();
      if (segment.isEmpty) continue;
      final parsed = _parseAmountSegment(segment);
      if (parsed != null) parts.add(parsed);
    }

    return parts.length >= 2
        ? parts
        : (parseExpenseMessage(original) == null
            ? const []
            : [parseExpenseMessage(original)!]);
  }

  static Map<String, dynamic>? _parseAmountSegment(String segment) {
    final normalized = _normalize(segment);
    final amount = _extractAmount(normalized);
    if (amount == null || amount <= 0 || amount > 999999999) return null;

    final isIncome = _looksLikeIncome(normalized);
    final detected = _detectCategory(normalized, isIncome: isIncome);
    final explicitLabel = isIncome ? null : _explicitExpenseLabel(normalized);

    return {
      'amount': amount,
      'category': explicitLabel ?? detected,
      'isExpense': !isIncome,
      'note': segment,
      'confidence': _confidence(normalized, explicitLabel ?? detected),
    };
  }

  static String _normalize(String input) {
    return CategoryUtils.normalize(input).replaceAll(',', '').trim();
  }

  static String? matchExpenseCategoryFromList(
      String text, List<String> categories) {
    final sorted = categories
        .where((c) =>
            c.trim().isNotEmpty &&
            CategoryUtils.key(c) != CategoryUtils.key('أخرى'))
        .toList()
      ..sort((a, b) {
        final tokenCompare = CategoryUtils.meaningfulTokens(b)
            .length
            .compareTo(CategoryUtils.meaningfulTokens(a).length);
        if (tokenCompare != 0) return tokenCompare;
        return b.length.compareTo(a.length);
      });

    // 1) Prefer exact/custom category name matches from the user's text.
    for (final category in sorted) {
      if (CategoryUtils.textMatchesCategory(text, category)) return category;
    }
    return null;
  }

  static double? _extractAmount(String normalized) {
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(normalized);
    if (match != null) return double.tryParse(match.group(1)!);

    // Lightweight Arabic word amounts for common voice cases.
    final words = normalized.split(RegExp(r'\s+'));
    double total = 0;
    bool found = false;
    for (final word in words) {
      final value = _numberWords[word];
      if (value != null) {
        total += value;
        found = true;
      }
    }
    return found ? total : null;
  }

  static bool _looksLikeIncome(String normalized) {
    return _incomeKeywords.any(normalized.contains) &&
        !_expenseOnlyKeywords.any(normalized.contains);
  }

  static String _detectCategory(String normalized, {required bool isIncome}) {
    final categories = isIncome ? _incomeCategories : _expenseCategories;
    for (final item in categories) {
      final keywords = item['keywords'] as List<String>;
      if (keywords.any(normalized.contains)) return item['category'] as String;
    }
    return isIncome ? 'أخرى' : 'أخرى';
  }

  static String? _explicitExpenseLabel(String normalized) {
    final stopWords = {
      ..._moneyWords,
      ..._actionWords,
      ..._expenseOnlyKeywords,
      'و',
      'ثم',
      'كمان',
      'وبعد',
      'بعد',
      'كده',
      'على',
      'علي',
      'في',
      'من',
      'ب',
    };
    final label = normalized
        .replaceAll(RegExp(r'\d+(?:\.\d+)?'), ' ')
        .replaceAll(RegExp(r'[،,]'), ' ')
        .split(RegExp(r'\s+'))
        .map((word) => word.trim())
        .where((word) => word.isNotEmpty && !stopWords.contains(word))
        .join(' ')
        .trim();
    if (label.isEmpty) return null;

    final key = CategoryUtils.key(label);
    if (key.isEmpty || key == CategoryUtils.key('أخرى')) return null;
    const canonical = {
      'ايجار': 'إيجار',
      'كهربا': 'كهرباء',
      'كهرباء': 'كهرباء',
      'مياه': 'مياه',
      'ميه': 'مياه',
      'غاز': 'غاز',
      'انترنت': 'إنترنت',
      'نت': 'إنترنت',
    };
    return canonical[key] ?? label;
  }

  static double _confidence(String normalized, String category) {
    var score = 0.55;
    if (category != 'أخرى') score += 0.25;
    if (_moneyWords.any(normalized.contains)) score += 0.1;
    if (_actionWords.any(normalized.contains)) score += 0.1;
    return score.clamp(0.0, 1.0).toDouble();
  }

  static bool isNextReportCommand(String text) {
    final normalized = _normalize(text);
    return normalized == 'التالي' ||
        normalized == 'التالى' ||
        normalized == 'كمل' ||
        normalized == 'اكمل' ||
        normalized == 'اللي بعده';
  }

  static Map<String, dynamic>? parseReportRequest(String text) {
    final original = text.trim();
    if (original.isEmpty) return null;
    final normalized = _normalize(original);
    final asksReport = normalized.contains('تقرير') ||
        normalized.contains('تقارير') ||
        normalized.contains('ملخص') ||
        normalized.contains('صرف مين') ||
        normalized.contains('مصروفات') ||
        normalized.contains('مصاريف') ||
        normalized.contains('ميزانيه') ||
        normalized.contains('ميزانية') ||
        normalized.contains('الباقي') ||
        normalized.contains('المتبقي') ||
        normalized.contains('حدود');
    if (!asksReport) return null;

    var days = 30;
    if (normalized.contains('اليوم') || normalized.contains('نهارده')) days = 1;
    if (normalized.contains('اسبوع') || normalized.contains('اسبوع')) days = 7;
    if (normalized.contains('شهر')) days = 30;
    if (normalized.contains('سنه') || normalized.contains('سنة')) days = 365;

    String? memberName;
    final memberPatterns = [
      RegExp(
          r'(?:مصاريف|مصروفات|تقرير|صرف)\s+(?:ابني|بنتي|مراتي|زوجتي|الولد|البنت|ل)?\s*([\u0600-\u06FF]{2,})'),
      RegExp(r'(?:عن|لـ|ل|بتاع)\s+([\u0600-\u06FF]{2,})'),
    ];
    for (final pattern in memberPatterns) {
      final match = pattern.firstMatch(normalized);
      if (match != null) {
        final candidate = match.group(1)?.trim();
        if (candidate != null &&
            !_reportStopWords.contains(candidate) &&
            candidate.length >= 2) {
          memberName = candidate;
          break;
        }
      }
    }

    return {
      'days': days,
      'memberName': memberName,
      'includeBudgets': true,
      'original': original,
    };
  }

  static const _reportStopWords = {
    'اخر',
    'آخر',
    'اسبوع',
    'اسبوعي',
    'شهر',
    'اليوم',
    'نهارده',
    'النهارده',
    'نهاردة',
    'النهاردة',
    'كده',
    'كذا',
    'انا',
    'اني',
    'ان',
    'قولي',
    'قولى',
    'صرفته',
    'مصروف',
    'مصاريف',
    'العيله',
    'العائلة',
  };

  static String formatExpenseText(Map<String, dynamic> result) {
    final amount = result['amount'] as double;
    final category = result['category'] as String;
    final isExpense = result['isExpense'] as bool;
    final prefix = isExpense ? 'مصروف' : 'دخل';
    final amountText = amount.truncateToDouble() == amount
        ? amount.toStringAsFixed(0)
        : amount.toStringAsFixed(2);
    return '$prefix $amountText ج — $category';
  }

  static const _numberWords = <String, double>{
    'واحد': 1,
    'واحده': 1,
    'اتنين': 2,
    'اثنين': 2,
    'تلاته': 3,
    'ثلاثه': 3,
    'اربعه': 4,
    'خمسه': 5,
    'سته': 6,
    'سبعه': 7,
    'تمانيه': 8,
    'ثمانيه': 8,
    'تسعه': 9,
    'عشره': 10,
    'عشرين': 20,
    'تلاتين': 30,
    'ثلاثين': 30,
    'اربعين': 40,
    'خمسين': 50,
    'ستين': 60,
    'سبعين': 70,
    'تمانين': 80,
    'ثمانين': 80,
    'تسعين': 90,
    'ميه': 100,
    'مائه': 100,
    'مئة': 100,
    'الف': 1000,
  };

  static const _moneyWords = ['جنيه', 'جنيهات', 'ج', 'egp', 'درهم', 'ريال'];
  static const _actionWords = [
    'دفعت',
    'صرفت',
    'اشتريت',
    'اديت',
    'اعطيت',
    'سجل',
    'ضيف',
    'اضف',
    'دخل',
    'قبضت'
  ];
  static const _incomeKeywords = [
    'دخل',
    'راتب',
    'مرتب',
    'قبض',
    'قبضت',
    'ايراد',
    'تحويل',
    'عموله',
    'مكافاه'
  ];
  static const _expenseOnlyKeywords = [
    'دفعت',
    'صرفت',
    'اشتريت',
    'اديت',
    'اعطيت',
    'خصم'
  ];

  static const List<Map<String, Object>> _expenseCategories = [
    {
      'category': 'أكل ومشروبات',
      'keywords': [
        'سوبر ماركت',
        'سوبر',
        'بقاله',
        'اكل',
        'مطعم',
        'كافيه',
        'قهوه',
        'خضار',
        'فراخ',
        'لحمه',
        'عيش'
      ]
    },
    {
      'category': 'مواصلات',
      'keywords': [
        'مواصلات',
        'بنزين',
        'سولار',
        'باص',
        'ميكروباص',
        'تاكسي',
        'اوبر',
        'كريم',
        'مترو',
        'جراج'
      ]
    },
    {
      'category': 'إيجار',
      'keywords': ['ايجار', 'شقه', 'سكن']
    },
    {
      'category': 'كهرباء',
      'keywords': ['كهربا', 'كهرباء', 'نور']
    },
    {
      'category': 'مياه',
      'keywords': ['مياه', 'ميه']
    },
    {
      'category': 'غاز',
      'keywords': ['غاز']
    },
    {
      'category': 'إنترنت',
      'keywords': ['انترنت', 'نت', 'واي فاي', 'راوتر']
    },
    {
      'category': 'اتصالات',
      'keywords': [
        'تليفون',
        'موبايل',
        'رصيد',
        'فودافون',
        'اتصالات',
        'اورنج',
        'وي'
      ]
    },
    {
      'category': 'تعليم',
      'keywords': ['مدرسه', 'جامعه', 'دروس', 'كتب', 'مصروفات مدرسه']
    },
    {
      'category': 'صحة',
      'keywords': ['دكتور', 'مستشفى', 'علاج', 'دواء', 'صيدليه', 'كشف']
    },
    {
      'category': 'ملابس',
      'keywords': ['ملابس', 'هدوم', 'حذاء', 'جزمه']
    },
    {
      'category': 'ترفيه',
      'keywords': ['سينما', 'خروج', 'لعب', 'رحله']
    },
    {
      'category': 'هدايا',
      'keywords': ['هديه', 'هدية']
    },
  ];

  static const List<Map<String, Object>> _incomeCategories = [
    {
      'category': 'راتب',
      'keywords': ['راتب', 'مرتب', 'قبض']
    },
    {
      'category': 'عمل حر',
      'keywords': ['فريلانس', 'عمل حر', 'شغل', 'عموله']
    },
    {
      'category': 'هدية',
      'keywords': ['هديه', 'هدية']
    },
    {
      'category': 'استثمار',
      'keywords': ['استثمار', 'ارباح', 'فوائد']
    },
  ];
}
