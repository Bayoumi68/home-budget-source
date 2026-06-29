import '../utils/category_utils.dart';

class AIService {
  // Local Arabic-first parser. It is intentionally offline: no API key, no internet.
  // Examples:
  //   "دفعت 250 جنيه سوبر ماركت" -> expense / 250 / سوبر ماركت
  //   "سجل دخل 12000 مرتب" -> income / 12000 / راتب
  //   "بنزين ب ٣٠٠" -> expense / 300 / بنزين

  static Map<String, dynamic>? parseExpenseMessage(String text) {
    final original = text.trim();
    if (original.isEmpty) return null;

    final normalized = _normalize(original);
    final amount = _extractAmount(normalized);
    if (amount == null || amount <= 0 || amount > 999999999) return null;

    final isIncome = _looksLikeIncome(normalized);
    final detected = _detectCategory(normalized, isIncome: isIncome);
    final explicitLabel = isIncome ? null : _explicitExpenseLabel(normalized);
    final category = _chooseExpenseCategory(
      detected: detected,
      explicitLabel: explicitLabel,
      isIncome: isIncome,
    );

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
    final amountMatches = RegExp(r'(?<!\d)(\d+(?:\.\d+)?)(?!\d)')
        .allMatches(normalized)
        .where((m) => !_isQuantity(normalized, m))
        .toList();
    if (amountMatches.length <= 1) {
      final single = parseExpenseMessage(original);
      return single == null ? const [] : [single];
    }

    final parts = <Map<String, dynamic>>[];
    for (var i = 0; i < amountMatches.length; i++) {
      final start = _segmentStartForAmount(normalized, amountMatches[i].start);
      final end = _segmentEndForAmount(
        normalized,
        amountMatches[i].end,
        i + 1 < amountMatches.length ? amountMatches[i + 1].start : null,
      );
      final segment = _trimSegment(normalized.substring(start, end));
      if (segment.isEmpty) continue;
      final parsed = _parseAmountSegment(segment);
      if (parsed != null) parts.add(parsed);
    }

    if (parts.length >= 2) return parts;
    final single = parseExpenseMessage(original);
    return single == null ? const [] : [single];
  }

  static int _segmentStartForAmount(String normalized, int amountStart) {
    var start = 0;
    for (final boundary in _expenseSeparators(normalized)) {
      if (boundary.end <= amountStart) start = boundary.end;
    }
    return start;
  }

  static int _segmentEndForAmount(
    String normalized,
    int amountEnd,
    int? nextAmountStart,
  ) {
    final hardEnd = nextAmountStart ?? normalized.length;
    for (final boundary in _expenseSeparators(normalized)) {
      if (boundary.start >= amountEnd && boundary.start < hardEnd) {
        return boundary.start;
      }
    }
    return hardEnd;
  }

  static List<({int start, int end})> _expenseSeparators(String text) {
    final boundaries = <({int start, int end})>[];
    final wordSeparators = RegExp(
      r'(?:،|,|\s+ثم\s+|\s+كمان\s+|\s+وبعد\s+كده\s+|\s+بعد\s+كده\s+)',
    );
    for (final match in wordSeparators.allMatches(text)) {
      boundaries.add((start: match.start, end: match.end));
    }

    final connectors = RegExp(r'(^|[\s،,])(و)(?=[\d\u0600-\u06FF])');
    for (final match in connectors.allMatches(text)) {
      final prefixLength = match.group(1)!.length;
      final connectorStart = match.start + prefixLength;
      boundaries.add((start: connectorStart, end: connectorStart + 1));
    }

    boundaries.sort((a, b) => a.start.compareTo(b.start));
    return boundaries;
  }

  static String _trimSegment(String segment) {
    return segment
        .replaceFirst(RegExp(r'^[\s،,و]+'), '')
        .replaceFirst(RegExp(r'[\s،,و]+$'), '')
        .trim();
  }

  static Map<String, dynamic>? _parseAmountSegment(String segment) {
    final normalized = _normalize(segment);
    final amount = _extractAmount(normalized);
    if (amount == null || amount <= 0 || amount > 999999999) return null;

    final isIncome = _looksLikeIncome(normalized);
    final detected = _detectCategory(normalized, isIncome: isIncome);
    final explicitLabel = isIncome ? null : _explicitExpenseLabel(normalized);
    final category = _chooseExpenseCategory(
      detected: detected,
      explicitLabel: explicitLabel,
      isIncome: isIncome,
    );

    return {
      'amount': amount,
      'category': category,
      'isExpense': !isIncome,
      'note': segment,
      'confidence': _confidence(normalized, category),
    };
  }

  static String _chooseExpenseCategory({
    required String detected,
    required String? explicitLabel,
    required bool isIncome,
  }) {
    if (isIncome) return detected;
    if (detected != 'أخرى' &&
        _preferDetectedExpenseCategories.contains(detected)) {
      return detected;
    }
    return explicitLabel ?? detected;
  }

  static String _normalize(String input) {
    return CategoryUtils.normalize(input).replaceAll(',', '').trim();
  }

  // A number right before one of these units is a quantity (count), not a price.
  static final RegExp _quantityUnitRe = RegExp(
      r'^\s*(?:كيلو|كيلوات|كجم|كيلوجرام|جرام|جم|علبه|علبة|عبوه|عبوة|قطعه|قطعة|'
      r'كرتونه|كرتونة|زجاجه|زجاجة|لتر|لتره|متر|امتار|كوب|اكواب|كيس|اكياس|رغيف|'
      r'ارغفه|عدد|نفر|افراد|فرد|دسته|دستة|باكو|باكت)(?:\s|$)');

  // A money word right after a number marks it as the amount (e.g. "300 ج").
  static final RegExp _moneyAfterRe =
      RegExp(r'^\s*(?:جنيه|جنيهات|ج|egp|درهم|ريال)(?:\s|$)');

  static bool _isQuantity(String normalized, RegExpMatch m) {
    return _quantityUnitRe.hasMatch(normalized.substring(m.end));
  }

  static const _refundKeywords = [
    'مرتجع',
    'استرجعت',
    'استرجاع',
    'استرداد',
    'استرجعوا',
    'رجعولي',
    'رجعوا فلوس',
  ];

  /// Capped Levenshtein distance for cheap typo tolerance.
  static int _editDistance(String a, String b) {
    if ((a.length - b.length).abs() > 2) return 99;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var min = cur[j - 1] + 1;
        if (prev[j] + 1 < min) min = prev[j] + 1;
        if (prev[j - 1] + cost < min) min = prev[j - 1] + cost;
        cur[j] = min;
      }
      prev = cur;
    }
    return prev[b.length];
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

    for (final category in sorted) {
      if (CategoryUtils.textMatchesCategory(text, category)) return category;
    }
    return null;
  }

  static double? _extractAmount(String normalized) {
    final matches =
        RegExp(r'(?<!\d)(\d+(?:\.\d+)?)(?!\d)').allMatches(normalized).toList();
    if (matches.isEmpty) {
      // Spelled-out Arabic numbers (e.g. "خمسين", "ميه").
      double total = 0;
      bool found = false;
      for (final word in normalized.split(RegExp(r'\s+'))) {
        final value = _numberWords[word];
        if (value != null) {
          total += value;
          found = true;
        }
      }
      return found ? total : null;
    }
    double? best;
    int bestScore = -1;
    double largest = 0;
    for (final m in matches) {
      final val = double.tryParse(m.group(1)!);
      if (val == null || val <= 0) continue;
      if (val > largest) largest = val;
      if (_isQuantity(normalized, m)) continue; // "2 كيلو" → count, not price
      final before = normalized.substring(0, m.start);
      final after = normalized.substring(m.end);
      var score = 0;
      if (RegExp(r'ب\s*$').hasMatch(before)) score += 5; // "بـ300"
      if (_moneyAfterRe.hasMatch(after)) score += 6; // "300 ج"
      if (val >= 10) score += 1; // prices are usually ≥ 10
      final better = best == null ||
          score > bestScore ||
          (score == bestScore && val > best);
      if (better) {
        best = val;
        bestScore = score;
      }
    }
    // If every number looked like a quantity, fall back to the largest one.
    best ??= largest > 0 ? largest : null;
    return best;
  }

  static bool _looksLikeIncome(String normalized) {
    // A refund/return means money coming back → treat as income.
    if (_refundKeywords.any(normalized.contains)) return true;
    return _incomeKeywords.any(normalized.contains) &&
        !_expenseOnlyKeywords.any(normalized.contains);
  }

  static String _detectCategory(String normalized, {required bool isIncome}) {
    final categories = isIncome ? _incomeCategories : _expenseCategories;
    final tokens = normalized
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 2)
        .toList();
    String best = 'أخرى';
    int bestScore = 0;
    for (final item in categories) {
      final keywords = item['keywords'] as List<String>;
      var score = 0;
      for (final kw in keywords) {
        if (normalized.contains(kw)) {
          // Direct hit; multi-word and longer keywords are more specific.
          score += kw.contains(' ') ? 3 : 2;
          if (kw.length >= 5) score += 1;
        } else if (!kw.contains(' ') && kw.length >= 4) {
          // Fuzzy: a token within 1 edit of the keyword (typo tolerance).
          for (final t in tokens) {
            if (_editDistance(t, kw) <= 1) {
              score += 1;
              break;
            }
          }
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = item['category'] as String;
      }
    }
    return best;
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
      'ل',
      'عن',
      'جبت',
      'اخدت',
      'خدت',
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
      'الايجار': 'إيجار',
      'كهربا': 'كهرباء',
      'كهرباء': 'كهرباء',
      'مياه': 'مياه',
      'ميه': 'مياه',
      'غاز': 'غاز',
      'انترنت': 'إنترنت',
      'نت': 'إنترنت',
      'سوبرماركت': 'سوبر ماركت',
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

  // Normalized phrases that mean "put cash INTO a wallet" (a top-up, not income
  // and not an expense). Normalization already maps ة→ه and ى→ي.
  static const _walletInjectionKeywords = [
    'حط في المحفظه',
    'حط المحفظه',
    'حط بالمحفظه',
    'حط فلوس في المحفظه',
    'نقديه وارده',
    'نقدية وارده',
    'وارد',
    'ايداع',
    'اودعت',
    'اضف للمحفظه',
    'ضيف للمحفظه',
    'اضافه للمحفظه',
    'شحن المحفظه',
    'شحنت المحفظه',
    'زود المحفظه',
    'فلوس داخله',
    'دخلت المحفظه',
    'تعبئه محفظه',
    'اضف رصيد',
    'اضافه رصيد',
  ];

  /// Detects a "cash into wallet" message and returns `{amount, note, walletHint}`,
  /// or null. The amount is required; walletHint is any text after "محفظة".
  static Map<String, dynamic>? parseWalletInjection(String text) {
    final original = text.trim();
    if (original.isEmpty) return null;
    final normalized = _normalize(original);
    if (!_walletInjectionKeywords.any(normalized.contains)) return null;
    final amount = _extractAmount(normalized);
    if (amount == null || amount <= 0 || amount > 999999999) return null;
    String? walletHint;
    final m = RegExp(r'محفظه\s+([؀-ۿ]+)').firstMatch(normalized);
    if (m != null) walletHint = m.group(1)?.trim();
    return {
      'amount': amount,
      'note': original,
      'walletHint': walletHint,
    };
  }

  // Read-only wallet questions. Normalization maps ة→ه, ى→ي.
  static const _walletBalanceKeywords = [
    'رصيد المحفظه',
    'رصيد محفظتي',
    'رصيد محفظه',
    'كام في المحفظه',
    'فلوس المحفظه',
    'كام فلوس المحفظه',
  ];

  static const _walletMovementKeywords = [
    'حركه المحفظه',
    'حركه محفظه',
    'كشف حساب المحفظه',
    'كشف المحفظه',
    'كشف حساب محفظه',
    'تقرير المحفظه',
    'تقرير محفظه',
    'سجل المحفظه',
  ];

  /// Detects "wallet balance" / "wallet movement" questions and returns
  /// `{type: 'balance'|'movement', walletHint}`, or null. No amount required.
  static Map<String, dynamic>? parseWalletQuery(String text) {
    final original = text.trim();
    if (original.isEmpty) return null;
    final normalized = _normalize(original);
    String? type;
    if (_walletMovementKeywords.any(normalized.contains)) {
      type = 'movement';
    } else if (_walletBalanceKeywords.any(normalized.contains)) {
      type = 'balance';
    } else {
      return null;
    }
    String? walletHint;
    final m = RegExp(r'محفظه\s+([؀-ۿ]+)').firstMatch(normalized);
    if (m != null) walletHint = m.group(1)?.trim();
    return {'type': type, 'walletHint': walletHint};
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
    if (normalized.contains('اليوم') || normalized.contains('نهارده')) {
      days = 1;
    }
    if (normalized.contains('اسبوع')) days = 7;
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
    return '$prefix $amountText ج - $category';
  }

  static const _numberWords = <String, double>{
    'واحد': 1,
    'واحده': 1,
    'واحدة': 1,
    'اتنين': 2,
    'اثنين': 2,
    'تلاته': 3,
    'ثلاثه': 3,
    'ثلاثة': 3,
    'اربعه': 4,
    'اربعة': 4,
    'خمسه': 5,
    'خمسة': 5,
    'سته': 6,
    'ستة': 6,
    'سبعه': 7,
    'سبعة': 7,
    'تمانيه': 8,
    'ثمانيه': 8,
    'ثمانية': 8,
    'تسعه': 9,
    'تسعة': 9,
    'عشره': 10,
    'عشرة': 10,
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
    'مائة': 100,
    'مئة': 100,
    'الف': 1000,
  };

  static const _moneyWords = [
    'جنيه',
    'جنيهات',
    'ج',
    'egp',
    'درهم',
    'ريال',
  ];

  static const _actionWords = [
    'دفعت',
    'صرفت',
    'اشتريت',
    'جبت',
    'اخدت',
    'خدت',
    'اديت',
    'اعطيت',
    'سجل',
    'سجلت',
    'ضيف',
    'اضف',
    'دخل',
    'قبضت',
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
    'عمولة',
    'مكافاه',
    'مكافأة',
  ];

  static const _expenseOnlyKeywords = [
    'دفعت',
    'صرفت',
    'اشتريت',
    'جبت',
    'اخدت',
    'خدت',
    'اديت',
    'اعطيت',
    'خصم',
  ];

  static const _preferDetectedExpenseCategories = {
    'مواصلات',
    'تعليم',
    'صحة',
    'اتصالات',
    'إنترنت',
    'ملابس',
    'منظفات',
    'صيانة',
    'أجهزة منزلية',
    'اشتراكات',
    'رسوم وخدمات',
    'ترفيه',
    'هدايا',
  };

  static const List<Map<String, Object>> _expenseCategories = [
    {
      'category': 'أكل ومشروبات',
      'keywords': [
        'سوبر ماركت',
        'سوبر',
        'بقاله',
        'بقالة',
        'اكل',
        'أكل',
        'مطعم',
        'اكل بيت',
        'طلبات',
        'دليفري',
        'كشري',
        'فول',
        'طعمية',
        'جبنة',
        'لبن',
        'زبادي',
        'رز',
        'مكرونة',
        'سكر',
        'زيت',
        'شاي',
        'قهوة',
        'كافيه',
        'قهوه',
        'تموين',
        'جمعيه',
        'جمعية',
        'هايبر',
        'ماركت',
        'جبنه',
        'جبنة',
        'بيض',
        'لانشون',
        'عسل',
        'مربى',
        'مربي',
        'بطاطس',
        'طماطم',
        'بصل',
        'رز',
        'ارز',
        'مكرونه',
        'مكرونة',
        'بقوليات',
        'عدس',
        'فول',
        'سكر',
        'زيت',
        'دقيق',
        'لبن',
        'زبادي',
        'مياه معدنيه',
        'مياه معدنية',
        'خضار',
        'فاكهة',
        'فواكه',
        'فراخ',
        'دجاج',
        'لحمه',
        'لحمة',
        'سمك',
        'عيش',
      ],
    },
    {
      'category': 'مواصلات',
      'keywords': [
        'مواصلات',
        'مواصله',
        'مواصلة',
        'مشوار',
        'مشاوير',
        'بنزين',
        'سولار',
        'باص',
        'اتوبيس',
        'أتوبيس',
        'ميكروباص',
        'تاكسي',
        'اوبر',
        'أوبر',
        'وبر',
        'uber',
        'كريم',
        'ديدي',
        'اندرايف',
        'inDrive',
        'توكتوك',
        'توك توك',
        'مترو',
        'قطر',
        'قطار',
        'تذكرة',
        'تذكره',
        'جراج',
        'ركنة',
        'ركنه',
        'موقف',
        'كارته',
        'كارتة',
        'طريق',
        'نفق',
        'كوبري',
        'كوبريه',
      ],
    },
    {
      'category': 'إيجار',
      'keywords': [
        'ايجار',
        'إيجار',
        'شقه',
        'شقة',
        'سكن',
        'البيت',
        'الشقة',
        'عقار',
        'عمارة',
        'بواب',
        'حارس',
        'اتحاد ملاك'
      ],
    },
    {
      'category': 'كهرباء',
      'keywords': [
        'كهربا',
        'كهرباء',
        'نور',
        'عداد كهربا',
        'فاتورة كهربا',
        'شحن كارت الكهرباء',
        'كارت الكهرباء'
      ],
    },
    {
      'category': 'مياه',
      'keywords': ['مياه', 'ميه', 'فاتورة مياه', 'عداد مياه'],
    },
    {
      'category': 'غاز',
      'keywords': ['غاز', 'فاتورة غاز', 'أنبوبة', 'انبوبة', 'بوتاجاز'],
    },
    {
      'category': 'إنترنت',
      'keywords': [
        'انترنت',
        'إنترنت',
        'نت',
        'واي فاي',
        'راوتر',
        'باقه نت',
        'باقة نت',
        'اشتراك النت'
      ],
    },
    {
      'category': 'اتصالات',
      'keywords': [
        'تليفون',
        'موبايل',
        'رصيد',
        'كارت شحن',
        'شحن',
        'باقه',
        'باقة',
        'فودافون',
        'اتصالات',
        'اورنج',
        'شركة وي',
        'we',
      ],
    },
    {
      'category': 'تعليم',
      'keywords': [
        'مدرسه',
        'مدرسة',
        'مصاريف مدرسه',
        'مصاريف مدرسة',
        'جامعه',
        'جامعة',
        'دروس',
        'درس',
        'مدرس',
        'مدرس خصوصي',
        'مدرسين',
        'مستر',
        'حضانة',
        'حضانه',
        'سنتر',
        'كورس',
        'كتب',
        'مذكرة',
        'مذكره',
        'كراسة',
        'كراسه',
        'قلم'
      ],
    },
    {
      'category': 'صحة',
      'keywords': [
        'دكتور',
        'مستشفى',
        'مستشفي',
        'علاج',
        'دواء',
        'دوا',
        'ادويه',
        'أدوية',
        'صيدليه',
        'الصيدليه',
        'صيديليه',
        'الصيديليه',
        'صيدلية',
        'صيدلي',
        'روشته',
        'روشتة',
        'تحاليل',
        'تحليل',
        'اشعه',
        'أشعة',
        'اسنان',
        'أسنان',
        'نظارة',
        'نضارة',
        'كشف'
      ],
    },
    {
      'category': 'ملابس',
      'keywords': [
        'ملابس',
        'هدوم',
        'تيشيرت',
        'بنطلون',
        'حذاء',
        'كوتشي',
        'جزمه',
        'جزمة'
      ],
    },
    {
      'category': 'منظفات',
      'keywords': [
        'منظفات',
        'مسحوق',
        'مسحوق غسيل',
        'برسيل',
        'اريال',
        'تايد',
        'كلور',
        'ديتول',
        'صابون',
        'شاور',
        'شامبو',
        'معجون',
        'فرشة',
        'فوط',
        'مناديل',
        'ورق تواليت',
        'سائل مواعين',
        'مواعين',
        'مطهر',
        'ملمع',
        'مكنسه',
        'مقشة'
      ],
    },
    {
      'category': 'صيانة',
      'keywords': [
        'صيانة',
        'تصليح',
        'سباك',
        'كهربائي',
        'نجار',
        'نقاش',
        'محارة',
        'دهان',
        'بوية',
        'مواسير',
        'حنفية',
        'صرف',
        'تسليك',
        'قفل',
        'مفتاح',
        'تركيب',
        'قطع غيار',
        'ميكانيكي',
        'كاوتش',
        'زيت عربيه',
        'زيت عربية'
      ],
    },
    {
      'category': 'أجهزة منزلية',
      'keywords': [
        'جهاز',
        'اجهزه',
        'أجهزة',
        'تلاجة',
        'ثلاجه',
        'غسالة',
        'غساله',
        'بوتاجاز',
        'مروحة',
        'مروحه',
        'مكيف',
        'تكييف',
        'خلاط',
        'مكواه',
        'مكواة',
        'لمبة',
        'لمبه',
        'مشترك',
        'فيشة',
        'فيشه',
        'شاحن',
        'كابل'
      ],
    },
    {
      'category': 'اشتراكات',
      'keywords': [
        'اشتراك',
        'اشتراكات',
        'نادي',
        'جيم',
        'نتفلكس',
        'شاهد',
        'يوتيوب',
        'سبوتيفاي',
        'برنامج',
        'تطبيق',
        'عضويه',
        'عضوية'
      ],
    },
    {
      'category': 'رسوم وخدمات',
      'keywords': [
        'رسوم',
        'خدمات',
        'ضريبة',
        'ضريبه',
        'مخالفة',
        'مخالفه',
        'غرامة',
        'غرامه',
        'دمغة',
        'دمغه',
        'استخراج',
        'شهادة',
        'شهاده',
        'بطاقة',
        'بطاقه',
        'جواز',
        'رخصة',
        'رخصه',
        'بريد',
        'تحويل',
        'عمولة',
        'عموله'
      ],
    },
    {
      'category': 'ترفيه',
      'keywords': [
        'سينما',
        'خروج',
        'لعب',
        'ملاهي',
        'فسحة',
        'فسحه',
        'رحله',
        'رحلة'
      ],
    },
    {
      'category': 'هدايا',
      'keywords': ['هديه', 'هدية', 'عيد ميلاد', 'عزومة', 'عزومه'],
    },
  ];

  static const List<Map<String, Object>> _incomeCategories = [
    {
      'category': 'راتب',
      'keywords': ['راتب', 'مرتب', 'قبض'],
    },
    {
      'category': 'عمل حر',
      'keywords': ['فريلانس', 'عمل حر', 'شغل', 'عموله', 'عمولة'],
    },
    {
      'category': 'هدية',
      'keywords': ['هديه', 'هدية'],
    },
    {
      'category': 'استثمار',
      'keywords': ['استثمار', 'ارباح', 'أرباح', 'فوائد'],
    },
  ];
}
