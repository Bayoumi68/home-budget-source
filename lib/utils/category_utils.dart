class CategoryUtils {
  static String normalize(String value) {
    return value
        .replaceAll('٠', '0')
        .replaceAll('١', '1')
        .replaceAll('٢', '2')
        .replaceAll('٣', '3')
        .replaceAll('٤', '4')
        .replaceAll('٥', '5')
        .replaceAll('٦', '6')
        .replaceAll('٧', '7')
        .replaceAll('٨', '8')
        .replaceAll('٩', '9')
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي')
        .replaceAll('ة', 'ه')
        .replaceAll('ى', 'ي')
        .replaceAll('ـ', '')
        .toLowerCase()
        .trim();
  }

  static String key(String value) {
    final n = normalize(value);
    return n.replaceAll(RegExp(r'[^\u0600-\u06FFa-zA-Z0-9]+'), '').trim();
  }

  static List<String> meaningfulTokens(String value) {
    final tokens = <String>{};
    for (final raw in normalize(value)
        .split(RegExp(r'[^\u0600-\u06FFa-zA-Z0-9]+'))
        .map((w) => w.trim())
        .where((w) => w.length >= 2)) {
      void addToken(String token) {
        final clean = token.trim();
        if (clean.length >= 2 && !_stopWords.contains(clean)) tokens.add(clean);
      }

      addToken(raw);

      // Egyptian Arabic often writes attached prepositions: "لمحمد", "بفراخ", "والايجار".
      // Add a stripped variant so custom budgets like "محمد" and "فراخ" still match.
      var stripped = raw;
      var changed = true;
      while (changed && stripped.length > 3) {
        changed = false;
        for (final prefix in _attachedPrefixes) {
          if (stripped.startsWith(prefix) && stripped.length - prefix.length >= 2) {
            stripped = stripped.substring(prefix.length);
            addToken(stripped);
            changed = true;
            break;
          }
        }
      }

      // Remove common attached pronoun endings: "مصروفه", "مصروفها".
      for (final suffix in _attachedSuffixes) {
        if (raw.endsWith(suffix) && raw.length - suffix.length >= 2) {
          addToken(raw.substring(0, raw.length - suffix.length));
        }
      }
    }
    return tokens.toList();
  }

  static bool isSameCategory(String a, String b) => key(a) == key(b);

  static bool textMatchesCategory(String text, String category) {
    final textKey = key(text);
    final categoryKey = key(category);
    if (categoryKey.isEmpty) return false;
    if (textKey.contains(categoryKey) || categoryKey.contains(textKey)) return true;

    final catTokens = meaningfulTokens(category);
    if (catTokens.isEmpty) return false;
    final textTokens = meaningfulTokens(text).toSet();

    var matched = 0;
    for (final token in catTokens) {
      if (textTokens.contains(token) || textKey.contains(token)) matched++;
    }

    // For custom categories like "مصروف محمد", matching "محمد" is enough.
    if (catTokens.length <= 2) return matched >= 1;
    return matched >= 2;
  }

  static bool isThisMonth(DateTime date, [DateTime? now]) {
    final n = now ?? DateTime.now();
    return date.year == n.year && date.month == n.month;
  }

  static const _attachedPrefixes = ['وال', 'بال', 'كال', 'فال', 'لل', 'ال', 'و', 'ف', 'ب', 'ل', 'ك'];
  static const _attachedSuffixes = ['هما', 'هم', 'ها', 'ه', 'ي'];

  static const _stopWords = {
    'انا',
    'اني',
    'دفعت',
    'صرفت',
    'اشتريت',
    'اديت',
    'اعطيت',
    'سجلت',
    'جنيه',
    'جنيهات',
    'مصروف',
    'مصاريف',
    'نوع',
    'حد',
    'شهري',
    'الشهر',
    'الجديد',
    'القديم',
    'علي',
    'على',
    'الى',
    'الي',
    'في',
    'من',
    'مع',
    'بتاع',
    'بتاعت',
    'ل',
    'ال',
  };
}
