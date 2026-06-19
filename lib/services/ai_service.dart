import '../utils/category_utils.dart';

class AIService {
  // Local Arabic-first parser. It is intentionally offline: no API key, no internet.
  // Examples:
  //   "Ø¯ÙØ¹Øª 250 Ø¬Ù†ÙŠÙ‡ Ø³ÙˆØ¨Ø± Ù…Ø§Ø±ÙƒØª" -> expense / 250 / Ø£ÙƒÙ„ ÙˆÙ…Ø´Ø±ÙˆØ¨Ø§Øª
  //   "Ø³Ø¬Ù„ Ø¯Ø®Ù„ 12000 Ù…Ø±ØªØ¨" -> income / 12000 / Ø±Ø§ØªØ¨
  //   "Ø¨Ù†Ø²ÙŠÙ† Ø¨ Ù£Ù Ù " -> expense / 300 / Ù…ÙˆØ§ØµÙ„Ø§Øª

  static Map<String, dynamic>? parseExpenseMessage(String text) {
    final original = text.trim();
    if (original.isEmpty) return null;

    final normalized = _normalize(original);
    final amount = _extractAmount(normalized);
    if (amount == null || amount <= 0 || amount > 999999999) return null;

    final isIncome = _looksLikeIncome(normalized);
    final detected = _detectCategory(normalized, isIncome: isIncome);
    final explicitLabel = isIncome ? null : _explicitExpenseLabel(normalized);
    final category = explicitLabel ?? detected;

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

    return parts.length >= 2
        ? parts
        : (parseExpenseMessage(original) == null
            ? const []
            : [parseExpenseMessage(original)!]);
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
      r'(?:\u00d8\u0152|\u060c|,|\s+\u00d8\u00ab\u00d9\u2026\s+|\s+\u062b\u0645\s+|\s+\u00d9\u0192\u00d9\u2026\u00d8\u00a7\u00d9\u2020\s+|\s+\u0643\u0645\u0627\u0646\s+|\s+\u00d9\u02c6\u00d8\u00a8\u00d8\u00b9\u00d8\u00af\s+\u00d9\u0192\u00d8\u00af\u00d9\u2021\s+|\s+\u0648\u0628\u0639\u062f\s+\u0643\u062f\u0647\s+|\s+\u00d8\u00a8\u00d8\u00b9\u00d8\u00af\s+\u00d9\u0192\u00d8\u00af\u00d9\u2021\s+|\s+\u0628\u0639\u062f\s+\u0643\u062f\u0647\s+)');
    for (final match in wordSeparators.allMatches(text)) {
      boundaries.add((start: match.start, end: match.end));
    }

    final connectors = RegExp(r'(^|[\s\u00d8\u0152\u060c,])(\u00d9\u02c6|\u0648)(?=[\d\u0600-\u06FF\u00c0-\u024F])');
    for (final match in connectors.allMatches(text)) {
      final prefixLength = match.group(1)!.length;
      final connectorLength = match.group(2)!.length;
      final connectorStart = match.start + prefixLength;
      boundaries.add(
        (start: connectorStart, end: connectorStart + connectorLength),
      );
    }

    boundaries.sort((a, b) => a.start.compareTo(b.start));
    return boundaries;
  }
  static String _trimSegment(String segment) {
    return segment
        .replaceFirst(RegExp(r'^[\s\u00d8\u0152\u060c,\u00d9\u02c6\u0648]+'), '')
        .replaceFirst(RegExp(r'[\s\u00d8\u0152\u060c,\u00d9\u02c6\u0648]+$'), '')
        .trim();
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
            CategoryUtils.key(c) != CategoryUtils.key('Ø£Ø®Ø±Ù‰'))
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
    return isIncome ? 'Ø£Ø®Ø±Ù‰' : 'Ø£Ø®Ø±Ù‰';
  }

  static String? _explicitExpenseLabel(String normalized) {
    final stopWords = {
      ..._moneyWords,
      ..._actionWords,
      ..._expenseOnlyKeywords,
      'Ùˆ',
      'Ø«Ù…',
      'ÙƒÙ…Ø§Ù†',
      'ÙˆØ¨Ø¹Ø¯',
      'Ø¨Ø¹Ø¯',
      'ÙƒØ¯Ù‡',
      'Ø¹Ù„Ù‰',
      'Ø¹Ù„ÙŠ',
      'ÙÙŠ',
      'Ù…Ù†',
      'Ø¨',
      'جنيه',
      'جنيهات',
      'ج',
      'دفعت',
      'صرفت',
      'اشتريت',
      'سجل',
      'اضف',
      'ب',
    };
    final label = normalized
        .replaceAll(RegExp(r'\d+(?:\.\d+)?'), ' ')
        .replaceAll(RegExp(r'[ØŒ,]'), ' ')
        .split(RegExp(r'\s+'))
        .map((word) => word.trim())
        .where((word) => word.isNotEmpty && !stopWords.contains(word))
        .join(' ')
        .trim();
    if (label.isEmpty) return null;

    final key = CategoryUtils.key(label);
    if (key.isEmpty || key == CategoryUtils.key('Ø£Ø®Ø±Ù‰')) return null;
    const canonical = {
      'Ø§ÙŠØ¬Ø§Ø±': 'Ø¥ÙŠØ¬Ø§Ø±',
      'ايجار': 'إيجار',
      'ÙƒÙ‡Ø±Ø¨Ø§': 'ÙƒÙ‡Ø±Ø¨Ø§Ø¡',
      'ÙƒÙ‡Ø±Ø¨Ø§Ø¡': 'ÙƒÙ‡Ø±Ø¨Ø§Ø¡',
      'كهرباء': 'كهرباء',
      'Ù…ÙŠØ§Ù‡': 'Ù…ÙŠØ§Ù‡',
      'مياه': 'مياه',
      'Ù…ÙŠÙ‡': 'Ù…ÙŠØ§Ù‡',
      'ØºØ§Ø²': 'ØºØ§Ø²',
      'غاز': 'غاز',
      'Ø§Ù†ØªØ±Ù†Øª': 'Ø¥Ù†ØªØ±Ù†Øª',
      'Ù†Øª': 'Ø¥Ù†ØªØ±Ù†Øª',
    };
    return canonical[key] ?? label;
  }

  static double _confidence(String normalized, String category) {
    var score = 0.55;
    if (category != 'Ø£Ø®Ø±Ù‰') score += 0.25;
    if (_moneyWords.any(normalized.contains)) score += 0.1;
    if (_actionWords.any(normalized.contains)) score += 0.1;
    return score.clamp(0.0, 1.0).toDouble();
  }

  static bool isNextReportCommand(String text) {
    final normalized = _normalize(text);
    return normalized == 'Ø§Ù„ØªØ§Ù„ÙŠ' ||
        normalized == 'Ø§Ù„ØªØ§Ù„Ù‰' ||
        normalized == 'ÙƒÙ…Ù„' ||
        normalized == 'Ø§ÙƒÙ…Ù„' ||
        normalized == 'Ø§Ù„Ù„ÙŠ Ø¨Ø¹Ø¯Ù‡';
  }

  static Map<String, dynamic>? parseReportRequest(String text) {
    final original = text.trim();
    if (original.isEmpty) return null;
    final normalized = _normalize(original);
    final asksReport = normalized.contains('ØªÙ‚Ø±ÙŠØ±') ||
        normalized.contains('ØªÙ‚Ø§Ø±ÙŠØ±') ||
        normalized.contains('Ù…Ù„Ø®Øµ') ||
        normalized.contains('ØµØ±Ù Ù…ÙŠÙ†') ||
        normalized.contains('Ù…ØµØ±ÙˆÙØ§Øª') ||
        normalized.contains('Ù…ØµØ§Ø±ÙŠÙ') ||
        normalized.contains('Ù…ÙŠØ²Ø§Ù†ÙŠÙ‡') ||
        normalized.contains('Ù…ÙŠØ²Ø§Ù†ÙŠØ©') ||
        normalized.contains('Ø§Ù„Ø¨Ø§Ù‚ÙŠ') ||
        normalized.contains('Ø§Ù„Ù…ØªØ¨Ù‚ÙŠ') ||
        normalized.contains('Ø­Ø¯ÙˆØ¯');
    if (!asksReport) return null;

    var days = 30;
    if (normalized.contains('Ø§Ù„ÙŠÙˆÙ…') || normalized.contains('Ù†Ù‡Ø§Ø±Ø¯Ù‡')) days = 1;
    if (normalized.contains('Ø§Ø³Ø¨ÙˆØ¹') || normalized.contains('Ø§Ø³Ø¨ÙˆØ¹')) days = 7;
    if (normalized.contains('Ø´Ù‡Ø±')) days = 30;
    if (normalized.contains('Ø³Ù†Ù‡') || normalized.contains('Ø³Ù†Ø©')) days = 365;

    String? memberName;
    final memberPatterns = [
      RegExp(
          r'(?:Ù…ØµØ§Ø±ÙŠÙ|Ù…ØµØ±ÙˆÙØ§Øª|ØªÙ‚Ø±ÙŠØ±|ØµØ±Ù)\s+(?:Ø§Ø¨Ù†ÙŠ|Ø¨Ù†ØªÙŠ|Ù…Ø±Ø§ØªÙŠ|Ø²ÙˆØ¬ØªÙŠ|Ø§Ù„ÙˆÙ„Ø¯|Ø§Ù„Ø¨Ù†Øª|Ù„)?\s*([\u0600-\u06FF]{2,})'),
      RegExp(r'(?:Ø¹Ù†|Ù„Ù€|Ù„|Ø¨ØªØ§Ø¹)\s+([\u0600-\u06FF]{2,})'),
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
    'Ø§Ø®Ø±',
    'Ø¢Ø®Ø±',
    'Ø§Ø³Ø¨ÙˆØ¹',
    'Ø§Ø³Ø¨ÙˆØ¹ÙŠ',
    'Ø´Ù‡Ø±',
    'Ø§Ù„ÙŠÙˆÙ…',
    'Ù†Ù‡Ø§Ø±Ø¯Ù‡',
    'Ø§Ù„Ù†Ù‡Ø§Ø±Ø¯Ù‡',
    'Ù†Ù‡Ø§Ø±Ø¯Ø©',
    'Ø§Ù„Ù†Ù‡Ø§Ø±Ø¯Ø©',
    'ÙƒØ¯Ù‡',
    'ÙƒØ°Ø§',
    'Ø§Ù†Ø§',
    'Ø§Ù†ÙŠ',
    'Ø§Ù†',
    'Ù‚ÙˆÙ„ÙŠ',
    'Ù‚ÙˆÙ„Ù‰',
    'ØµØ±ÙØªÙ‡',
    'Ù…ØµØ±ÙˆÙ',
    'Ù…ØµØ§Ø±ÙŠÙ',
    'Ø§Ù„Ø¹ÙŠÙ„Ù‡',
    'Ø§Ù„Ø¹Ø§Ø¦Ù„Ø©',
  };

  static String formatExpenseText(Map<String, dynamic> result) {
    final amount = result['amount'] as double;
    final category = result['category'] as String;
    final isExpense = result['isExpense'] as bool;
    final prefix = isExpense ? 'Ù…ØµØ±ÙˆÙ' : 'Ø¯Ø®Ù„';
    final amountText = amount.truncateToDouble() == amount
        ? amount.toStringAsFixed(0)
        : amount.toStringAsFixed(2);
    return '$prefix $amountText Ø¬ â€” $category';
  }

  static const _numberWords = <String, double>{
    'ÙˆØ§Ø­Ø¯': 1,
    'ÙˆØ§Ø­Ø¯Ù‡': 1,
    'Ø§ØªÙ†ÙŠÙ†': 2,
    'Ø§Ø«Ù†ÙŠÙ†': 2,
    'ØªÙ„Ø§ØªÙ‡': 3,
    'Ø«Ù„Ø§Ø«Ù‡': 3,
    'Ø§Ø±Ø¨Ø¹Ù‡': 4,
    'Ø®Ù…Ø³Ù‡': 5,
    'Ø³ØªÙ‡': 6,
    'Ø³Ø¨Ø¹Ù‡': 7,
    'ØªÙ…Ø§Ù†ÙŠÙ‡': 8,
    'Ø«Ù…Ø§Ù†ÙŠÙ‡': 8,
    'ØªØ³Ø¹Ù‡': 9,
    'Ø¹Ø´Ø±Ù‡': 10,
    'Ø¹Ø´Ø±ÙŠÙ†': 20,
    'ØªÙ„Ø§ØªÙŠÙ†': 30,
    'Ø«Ù„Ø§Ø«ÙŠÙ†': 30,
    'Ø§Ø±Ø¨Ø¹ÙŠÙ†': 40,
    'Ø®Ù…Ø³ÙŠÙ†': 50,
    'Ø³ØªÙŠÙ†': 60,
    'Ø³Ø¨Ø¹ÙŠÙ†': 70,
    'ØªÙ…Ø§Ù†ÙŠÙ†': 80,
    'Ø«Ù…Ø§Ù†ÙŠÙ†': 80,
    'ØªØ³Ø¹ÙŠÙ†': 90,
    'Ù…ÙŠÙ‡': 100,
    'Ù…Ø§Ø¦Ù‡': 100,
    'Ù…Ø¦Ø©': 100,
    'Ø§Ù„Ù': 1000,
  };

  static const _moneyWords = ['Ø¬Ù†ÙŠÙ‡', 'Ø¬Ù†ÙŠÙ‡Ø§Øª', 'Ø¬', 'egp', 'Ø¯Ø±Ù‡Ù…', 'Ø±ÙŠØ§Ù„'];
  static const _actionWords = [
    'Ø¯ÙØ¹Øª',
    'ØµØ±ÙØª',
    'Ø§Ø´ØªØ±ÙŠØª',
    'Ø§Ø¯ÙŠØª',
    'Ø§Ø¹Ø·ÙŠØª',
    'Ø³Ø¬Ù„',
    'Ø¶ÙŠÙ',
    'Ø§Ø¶Ù',
    'Ø¯Ø®Ù„',
    'Ù‚Ø¨Ø¶Øª'
  ];
  static const _incomeKeywords = [
    'Ø¯Ø®Ù„',
    'Ø±Ø§ØªØ¨',
    'Ù…Ø±ØªØ¨',
    'Ù‚Ø¨Ø¶',
    'Ù‚Ø¨Ø¶Øª',
    'Ø§ÙŠØ±Ø§Ø¯',
    'ØªØ­ÙˆÙŠÙ„',
    'Ø¹Ù…ÙˆÙ„Ù‡',
    'Ù…ÙƒØ§ÙØ§Ù‡'
  ];
  static const _expenseOnlyKeywords = [
    'Ø¯ÙØ¹Øª',
    'ØµØ±ÙØª',
    'Ø§Ø´ØªØ±ÙŠØª',
    'Ø§Ø¯ÙŠØª',
    'Ø§Ø¹Ø·ÙŠØª',
    'Ø®ØµÙ…'
  ];

  static const List<Map<String, Object>> _expenseCategories = [
    {
      'category': 'Ø£ÙƒÙ„ ÙˆÙ…Ø´Ø±ÙˆØ¨Ø§Øª',
      'keywords': [
        'Ø³ÙˆØ¨Ø± Ù…Ø§Ø±ÙƒØª',
        'Ø³ÙˆØ¨Ø±',
        'Ø¨Ù‚Ø§Ù„Ù‡',
        'Ø§ÙƒÙ„',
        'Ù…Ø·Ø¹Ù…',
        'ÙƒØ§ÙÙŠÙ‡',
        'Ù‚Ù‡ÙˆÙ‡',
        'Ø®Ø¶Ø§Ø±',
        'ÙØ±Ø§Ø®',
        'Ù„Ø­Ù…Ù‡',
        'Ø¹ÙŠØ´'
      ]
    },
    {
      'category': 'Ù…ÙˆØ§ØµÙ„Ø§Øª',
      'keywords': [
        'Ù…ÙˆØ§ØµÙ„Ø§Øª',
        'Ø¨Ù†Ø²ÙŠÙ†',
        'Ø³ÙˆÙ„Ø§Ø±',
        'Ø¨Ø§Øµ',
        'Ù…ÙŠÙƒØ±ÙˆØ¨Ø§Øµ',
        'ØªØ§ÙƒØ³ÙŠ',
        'Ø§ÙˆØ¨Ø±',
        'ÙƒØ±ÙŠÙ…',
        'Ù…ØªØ±Ùˆ',
        'Ø¬Ø±Ø§Ø¬'
      ]
    },
    {
      'category': 'Ø¥ÙŠØ¬Ø§Ø±',
      'keywords': ['Ø§ÙŠØ¬Ø§Ø±', 'Ø´Ù‚Ù‡', 'Ø³ÙƒÙ†']
    },
    {
      'category': 'ÙƒÙ‡Ø±Ø¨Ø§Ø¡',
      'keywords': ['ÙƒÙ‡Ø±Ø¨Ø§', 'ÙƒÙ‡Ø±Ø¨Ø§Ø¡', 'Ù†ÙˆØ±']
    },
    {
      'category': 'Ù…ÙŠØ§Ù‡',
      'keywords': ['Ù…ÙŠØ§Ù‡', 'Ù…ÙŠÙ‡']
    },
    {
      'category': 'ØºØ§Ø²',
      'keywords': ['ØºØ§Ø²']
    },
    {
      'category': 'Ø¥Ù†ØªØ±Ù†Øª',
      'keywords': ['Ø§Ù†ØªØ±Ù†Øª', 'Ù†Øª', 'ÙˆØ§ÙŠ ÙØ§ÙŠ', 'Ø±Ø§ÙˆØªØ±']
    },
    {
      'category': 'Ø§ØªØµØ§Ù„Ø§Øª',
      'keywords': [
        'ØªÙ„ÙŠÙÙˆÙ†',
        'Ù…ÙˆØ¨Ø§ÙŠÙ„',
        'Ø±ØµÙŠØ¯',
        'ÙÙˆØ¯Ø§ÙÙˆÙ†',
        'Ø§ØªØµØ§Ù„Ø§Øª',
        'Ø§ÙˆØ±Ù†Ø¬',
        'ÙˆÙŠ'
      ]
    },
    {
      'category': 'ØªØ¹Ù„ÙŠÙ…',
      'keywords': ['Ù…Ø¯Ø±Ø³Ù‡', 'Ø¬Ø§Ù…Ø¹Ù‡', 'Ø¯Ø±ÙˆØ³', 'ÙƒØªØ¨', 'Ù…ØµØ±ÙˆÙØ§Øª Ù…Ø¯Ø±Ø³Ù‡']
    },
    {
      'category': 'ØµØ­Ø©',
      'keywords': ['Ø¯ÙƒØªÙˆØ±', 'Ù…Ø³ØªØ´ÙÙ‰', 'Ø¹Ù„Ø§Ø¬', 'Ø¯ÙˆØ§Ø¡', 'ØµÙŠØ¯Ù„ÙŠÙ‡', 'ÙƒØ´Ù']
    },
    {
      'category': 'Ù…Ù„Ø§Ø¨Ø³',
      'keywords': ['Ù…Ù„Ø§Ø¨Ø³', 'Ù‡Ø¯ÙˆÙ…', 'Ø­Ø°Ø§Ø¡', 'Ø¬Ø²Ù…Ù‡']
    },
    {
      'category': 'ØªØ±ÙÙŠÙ‡',
      'keywords': ['Ø³ÙŠÙ†Ù…Ø§', 'Ø®Ø±ÙˆØ¬', 'Ù„Ø¹Ø¨', 'Ø±Ø­Ù„Ù‡']
    },
    {
      'category': 'Ù‡Ø¯Ø§ÙŠØ§',
      'keywords': ['Ù‡Ø¯ÙŠÙ‡', 'Ù‡Ø¯ÙŠØ©']
    },
  ];

  static const List<Map<String, Object>> _incomeCategories = [
    {
      'category': 'Ø±Ø§ØªØ¨',
      'keywords': ['Ø±Ø§ØªØ¨', 'Ù…Ø±ØªØ¨', 'Ù‚Ø¨Ø¶']
    },
    {
      'category': 'Ø¹Ù…Ù„ Ø­Ø±',
      'keywords': ['ÙØ±ÙŠÙ„Ø§Ù†Ø³', 'Ø¹Ù…Ù„ Ø­Ø±', 'Ø´ØºÙ„', 'Ø¹Ù…ÙˆÙ„Ù‡']
    },
    {
      'category': 'Ù‡Ø¯ÙŠØ©',
      'keywords': ['Ù‡Ø¯ÙŠÙ‡', 'Ù‡Ø¯ÙŠØ©']
    },
    {
      'category': 'Ø§Ø³ØªØ«Ù…Ø§Ø±',
      'keywords': ['Ø§Ø³ØªØ«Ù…Ø§Ø±', 'Ø§Ø±Ø¨Ø§Ø­', 'ÙÙˆØ§Ø¦Ø¯']
    },
  ];
}


