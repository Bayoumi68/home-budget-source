import '../models/category_model.dart';
import '../utils/category_utils.dart';

class AIService {
  // Local Arabic-first parser. It is intentionally offline: no API key, no internet.
  // Examples:
  //   "دفعت 250 جنيه سوبر ماركت" -> expense / 250 / سوبر ماركت
  //   "سجل دخل 12000 مرتب" -> income / 12000 / راتب
  //   "بنزين ب ٣٠٠" -> expense / 300 / بنزين

  // ── Intent-first money commands ───────────────────────────────────────────
  // The VERB decides the action, not the presence of a number. Only when none
  // of these intent words appear does a message fall through to "expense".
  static const _addMoneyWords = ['اضافه', 'اضف']; // إضافة، أضف
  static const _transferWords = ['تحويل', 'حول', 'نقل']; // حول، تحويل، نقل
  static const _withdrawWords = ['اسحب', 'سحب']; // اسحب، سحب
  static const _raiseLimitWords = ['رفع حد', 'رفع الحد', 'تزويد', 'زود'];
  static const _lowerLimitWords = ['خفض', 'تخفيض', 'تنزيل حد', 'تنزيل الحد'];

  /// Detects a money COMMAND by its verb and returns
  /// `{intent, amount, fromHint, toHint}` — or null when there's no money verb
  /// (so the text can be treated as a plain expense). intent is one of:
  /// add | withdraw | transfer | raiseLimit | lowerLimit.
  static Map<String, dynamic>? parseMoneyCommand(String text) {
    final original = text.trim();
    if (original.isEmpty) return null;
    final n = _normalize(original);

    String? intent;
    if (_raiseLimitWords.any(n.contains)) {
      intent = 'raiseLimit';
    } else if (_lowerLimitWords.any(n.contains)) {
      intent = 'lowerLimit';
    } else if (_transferWords.any(n.contains)) {
      intent = 'transfer';
    } else if (_withdrawWords.any(n.contains)) {
      intent = 'withdraw';
    } else if (_addMoneyWords.any(n.contains)) {
      intent = 'add';
    } else {
      return null;
    }
    return {
      'intent': intent,
      'amount': _extractAmount(n),
      'fromHint': _hintAfter(n, const ['من']),
      'toHint': _hintAfter(n, const ['الي', 'إلي', 'الى']),
      'text': n,
    };
  }

  /// The phrase after a direction marker (من / إلى), cleaned of digits and the
  /// currency word, used to match a wallet or a person by name.
  static String? _hintAfter(String n, List<String> markers) {
    for (final mk in markers) {
      final idx = n.indexOf('$mk ');
      if (idx < 0) continue;
      var rest = n.substring(idx + mk.length + 1).trim();
      for (final stop in const ['الي', 'إلي', 'الى', ' من ']) {
        final si = rest.indexOf(stop);
        if (si > 0) rest = rest.substring(0, si).trim();
      }
      rest = rest
          .replaceAll(RegExp(r'[0-9٠-٩.,]+'), '')
          .replaceAll('جنيه', '')
          .replaceAll('محفظه', '')
          .trim();
      if (rest.isNotEmpty) return rest;
    }
    return null;
  }

  static Map<String, dynamic>? parseExpenseMessage(
    String text, {
    required List<CategoryModel> categories,
  }) {
    final original = text.trim();
    if (original.isEmpty) return null;
    // Intent-first: a money command (add/withdraw/transfer/limit) is never an
    // expense, even though it contains a number.
    if (parseMoneyCommand(original) != null) return null;

    final normalized = _normalize(original);
    final amount = _extractAmount(normalized);
    if (amount == null || amount <= 0 || amount > 999999999) return null;

    final isIncome = _looksLikeIncome(normalized);
    final detected =
        _detectCategory(normalized, categories, isIncome: isIncome);
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

  static List<Map<String, dynamic>> parseExpenseMessages(
    String text, {
    required List<CategoryModel> categories,
  }) {
    final original = text.trim();
    if (original.isEmpty) return const [];
    // A money command is never an expense (intent-first).
    if (parseMoneyCommand(original) != null) return const [];

    final normalized = _normalize(original);
    final amountMatches = RegExp(r'(?<!\d)(\d+(?:\.\d+)?)(?!\d)')
        .allMatches(normalized)
        .where((m) => !_isQuantity(normalized, m))
        .toList();
    if (amountMatches.length <= 1) {
      final single = parseExpenseMessage(original, categories: categories);
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
      final parsed = _parseAmountSegment(segment, categories);
      if (parsed != null) parts.add(parsed);
    }

    if (parts.length >= 2) return parts;
    final single = parseExpenseMessage(original, categories: categories);
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

  static Map<String, dynamic>? _parseAmountSegment(
      String segment, List<CategoryModel> categories) {
    final normalized = _normalize(segment);
    final amount = _extractAmount(normalized);
    if (amount == null || amount <= 0 || amount > 999999999) return null;

    final isIncome = _looksLikeIncome(normalized);
    final detected =
        _detectCategory(normalized, categories, isIncome: isIncome);
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

  // Trust ANY keyword-detected category, not just an allow-listed subset.
  // (Previously an allow-list excluded food/rent/electricity/water/gas,
  // which is why those expenses fell back to raw leftover text instead of
  // their canonical bucket name — that inconsistency is fixed here.)
  static String _chooseExpenseCategory({
    required String detected,
    required String? explicitLabel,
    required bool isIncome,
  }) {
    if (isIncome) return detected;
    if (detected != 'أخرى') return detected;
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

  static String _detectCategory(
    String normalized,
    List<CategoryModel> categories, {
    required bool isIncome,
  }) {
    final relevant = categories.where((c) => c.isIncome == isIncome);
    final tokens = normalized
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 2)
        .toList();
    String best = 'أخرى';
    int bestScore = 0;
    for (final item in relevant) {
      var score = 0;
      for (final kw in item.keywords) {
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
        best = item.name;
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
    // "إضافة" (the noun the admin types to fund). A money amount is required by
    // the parser anyway, so "إضافة 500" funds the wallet instead of spending.
    // Kept to the noun form only — the verb "اضف/ضيف" is too greedy and would
    // swallow real expenses like "اضفت ...".
    'اضافه',
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
    final n = _normalize(text); // maps ى→ي, so التالى → التالي
    if (n == 'كمل' || n == 'اكمل') return true;
    return n.contains('التالي') ||
        n.contains('اللي بعده') ||
        n.contains('باقي التقرير') ||
        n.contains('كمل التقرير');
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

  // NOTE: the old hardcoded _expenseCategories/_incomeCategories keyword
  // tables (and the _preferDetectedExpenseCategories allow-list gate that
  // caused inconsistent categorization) have been removed — see
  // lib/data/category_seeds.dart, which is the seeded, per-family-editable
  // replacement now passed into _detectCategory via the `categories` param.
}
