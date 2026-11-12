/// Search filter constants for book search API
library;

/// One language entry in the search filter: the API value sent to
/// Z-Library plus its display name in each shipped locale.
///
/// Single source of truth for the language filter (previously two
/// parallel tables: [searchLanguages] with 48 API values and the
/// 34-entry display-name tables in [getLanguageDisplayNames] — 14
/// languages were unreachable in the filter UI because they had no
/// display name; they are now listed with standard translations).
class SearchLanguage {
  /// Value sent to the API (`null` = all languages).
  final String? apiValue;

  /// Display names: Simplified Chinese / Traditional Chinese / English.
  final String zh;
  final String zhHant;
  final String en;

  const SearchLanguage({
    required this.apiValue,
    required this.zh,
    required this.zhHant,
    required this.en,
  });

  /// Display name for [locale], using the same matching as the old
  /// display-name tables: zh_Hant (incl. zh_TW / zh_HK / zh_MO)
  /// first, then generic zh, otherwise English.
  String displayName(String locale) {
    final lowerLocale = locale.toLowerCase();
    if (lowerLocale.startsWith('zh_hant') ||
        lowerLocale.startsWith('zh-hant') ||
        lowerLocale == 'zh_tw' ||
        lowerLocale.startsWith('zh_tw') ||
        lowerLocale == 'zh_hk' ||
        lowerLocale.startsWith('zh_hk') ||
        lowerLocale == 'zh_mo') {
      return zhHant;
    }
    if (locale.startsWith('zh')) return zh;
    return en;
  }
}

/// All search languages, in filter-sheet order: the 34 previously
/// displayed languages first (unchanged order), then the 14 that
/// were API-only and never shown in the UI.
const searchLanguageOptions = <String, SearchLanguage>{
  'all': SearchLanguage(apiValue: null, zh: '所有語言', zhHant: '所有語言', en: '所有語言'),
  'chinese': SearchLanguage(apiValue: 'chinese', zh: '簡體中文', zhHant: '簡體中文', en: '簡體中文'),
  'traditional_chinese': SearchLanguage(apiValue: 'traditional chinese', zh: '繁體中文', zhHant: '繁體中文', en: '繁體中文'),
  'english': SearchLanguage(apiValue: 'english', zh: '英語', zhHant: '英語', en: '英語'),
  'russian': SearchLanguage(apiValue: 'russian', zh: '俄語', zhHant: '俄語', en: '俄語'),
  'german': SearchLanguage(apiValue: 'german', zh: '德語', zhHant: '德語', en: '德語'),
  'spanish': SearchLanguage(apiValue: 'spanish', zh: '西班牙語', zhHant: '西班牙語', en: '西班牙語'),
  'french': SearchLanguage(apiValue: 'french', zh: '法語', zhHant: '法語', en: '法語'),
  'italian': SearchLanguage(apiValue: 'italian', zh: '意大利語', zhHant: '意大利語', en: '意大利語'),
  'portuguese': SearchLanguage(apiValue: 'portuguese', zh: '葡萄牙語', zhHant: '葡萄牙語', en: '葡萄牙語'),
  'brazilian': SearchLanguage(apiValue: 'brazilian', zh: '巴西葡萄牙語', zhHant: '巴西葡萄牙語', en: '巴西葡萄牙語'),
  'japanese': SearchLanguage(apiValue: 'japanese', zh: '日語', zhHant: '日語', en: '日語'),
  'korean': SearchLanguage(apiValue: 'korean', zh: '韓語', zhHant: '韓語', en: '韓語'),
  'arabic': SearchLanguage(apiValue: 'arabic', zh: '阿拉伯語', zhHant: '阿拉伯語', en: '阿拉伯語'),
  'turkish': SearchLanguage(apiValue: 'turkish', zh: '土耳其語', zhHant: '土耳其語', en: '土耳其語'),
  'vietnamese': SearchLanguage(apiValue: 'vietnamese', zh: '越南語', zhHant: '越南語', en: '越南語'),
  'thai': SearchLanguage(apiValue: 'thai', zh: '泰語', zhHant: '泰語', en: '泰語'),
  'indonesian': SearchLanguage(apiValue: 'indonesian', zh: '印度尼西亞語', zhHant: '印度尼西亞語', en: '印度尼西亞語'),
  'polish': SearchLanguage(apiValue: 'polish', zh: '波蘭語', zhHant: '波蘭語', en: '波蘭語'),
  'ukrainian': SearchLanguage(apiValue: 'ukrainian', zh: '烏克蘭語', zhHant: '烏克蘭語', en: '烏克蘭語'),
  'dutch': SearchLanguage(apiValue: 'dutch', zh: '荷蘭語', zhHant: '荷蘭語', en: '荷蘭語'),
  'swedish': SearchLanguage(apiValue: 'swedish', zh: '瑞典語', zhHant: '瑞典語', en: '瑞典語'),
  'danish': SearchLanguage(apiValue: 'danish', zh: '丹麥語', zhHant: '丹麥語', en: '丹麥語'),
  'norwegian': SearchLanguage(apiValue: 'norwegian', zh: '挪威語', zhHant: '挪威語', en: '挪威語'),
  'finnish': SearchLanguage(apiValue: 'finnish', zh: '芬蘭語', zhHant: '芬蘭語', en: '芬蘭語'),
  'greek': SearchLanguage(apiValue: 'greek', zh: '希臘語', zhHant: '希臘語', en: '希臘語'),
  'czech': SearchLanguage(apiValue: 'czech', zh: '捷克語', zhHant: '捷克語', en: '捷克語'),
  'romanian': SearchLanguage(apiValue: 'romanian', zh: '羅馬尼亞語', zhHant: '羅馬尼亞語', en: '羅馬尼亞語'),
  'hungarian': SearchLanguage(apiValue: 'hungarian', zh: '匈牙利語', zhHant: '匈牙利語', en: '匈牙利語'),
  'persian': SearchLanguage(apiValue: 'persian', zh: '波斯語', zhHant: '波斯語', en: '波斯語'),
  'hindi': SearchLanguage(apiValue: 'hindi', zh: '印地語', zhHant: '印地語', en: '印地語'),
  'bengali': SearchLanguage(apiValue: 'bengali', zh: '孟加拉語', zhHant: '孟加拉語', en: '孟加拉語'),
  'hebrew': SearchLanguage(apiValue: 'hebrew', zh: '希伯來語', zhHant: '希伯來語', en: '希伯來語'),
  'latin': SearchLanguage(apiValue: 'latin', zh: '拉丁語', zhHant: '拉丁語', en: '拉丁語'),
  'bulgarian': SearchLanguage(apiValue: 'bulgarian', zh: '保加利亚语', zhHant: '保加利亞語', en: 'Bulgarian'),
  'moldavian': SearchLanguage(apiValue: 'moldavian', zh: '摩尔多瓦语', zhHant: '摩爾多瓦語', en: 'Moldavian'),
  'serbian': SearchLanguage(apiValue: 'serbian', zh: '塞尔维亚语', zhHant: '塞爾維亞語', en: 'Serbian'),
  'croatian': SearchLanguage(apiValue: 'croatian', zh: '克罗地亚语', zhHant: '克羅地亞語', en: 'Croatian'),
  'kazakh': SearchLanguage(apiValue: 'kazakh', zh: '哈萨克语', zhHant: '哈薩克語', en: 'Kazakh'),
  'belarusian': SearchLanguage(apiValue: 'belarusian', zh: '白俄罗斯语', zhHant: '白俄羅斯語', en: 'Belarusian'),
  'malaysian': SearchLanguage(apiValue: 'malaysian', zh: '马来语', zhHant: '馬來語', en: 'Malay'),
  'lithuanian': SearchLanguage(apiValue: 'lithuanian', zh: '立陶宛语', zhHant: '立陶宛語', en: 'Lithuanian'),
  'catalan': SearchLanguage(apiValue: 'catalan', zh: '加泰罗尼亚语', zhHant: '加泰隆尼亞語', en: 'Catalan'),
  'azerbaijani': SearchLanguage(apiValue: 'azerbaijani', zh: '阿塞拜疆语', zhHant: '亞塞拜然語', en: 'Azerbaijani'),
  'esperanto': SearchLanguage(apiValue: 'esperanto', zh: '世界语', zhHant: '世界語', en: 'Esperanto'),
  'urdu': SearchLanguage(apiValue: 'urdu', zh: '乌尔都语', zhHant: '烏爾都語', en: 'Urdu'),
  'uzbek': SearchLanguage(apiValue: 'uzbek', zh: '乌兹别克语', zhHant: '烏茲別克語', en: 'Uzbek'),
  'slovak': SearchLanguage(apiValue: 'slovak', zh: '斯洛伐克语', zhHant: '斯洛伐克語', en: 'Slovak'),
};

/// Language options for book search (API values, derived from
/// [searchLanguageOptions]; `null` = all languages).
final searchLanguages = <String, String?>{
  for (final entry in searchLanguageOptions.entries)
    entry.key: entry.value.apiValue,
};

/// Localized language display names (key: api_value), derived from
/// [searchLanguageOptions].
Map<String, String> getLanguageDisplayNames(String locale) {
  return {
    for (final entry in searchLanguageOptions.entries)
      entry.key: entry.value.displayName(locale),
  };
}

/// Sort order options
const searchOrders = {
  'default': null,
  'popular': 'popular',
  'bestmatch': 'bestmatch',
  'title': 'title',
  'date': 'date',
  'year': 'year',
};

/// Sort order options for full-text search ONLY. The site's
/// `/fulltext` sort has 8 values; the three missing from
/// [searchOrders] are `titleA`, `filesize` and `filesizeA`. These
/// must never be sent to the eapi search — the general-search UI
/// only ever offers [searchOrders], and the search screen switches
/// the sheet's sort list (and resets the selection) with the mode.
/// Site semantics, do not swap: `titleA` is A–Z, `title` is Z–A.
const fulltextSearchOrders = {
  'popular': 'popular',
  'bestmatch': 'bestmatch',
  'date': 'date',
  'titleA': 'titleA',
  'title': 'title',
  'year': 'year',
  'filesize': 'filesize',
  'filesizeA': 'filesizeA',
};

/// Localized full-text sort order names.
Map<String, String> getFulltextOrderDisplayNames(String locale) {
  if (locale.startsWith('zh')) {
    return {
      'popular': '最受欢迎',
      'bestmatch': '最佳吻合',
      'date': '最近添加',
      'titleA': '按名称 (A-Z)',
      'title': '按名称 (Z-A)',
      'year': '按年份',
      'filesize': '文件大小↓',
      'filesizeA': '文件大小↑',
    };
  }
  return {
    'popular': 'Most Popular',
    'bestmatch': 'Best Match',
    'date': 'Recently Added',
    'titleA': 'Title (A-Z)',
    'title': 'Title (Z-A)',
    'year': 'Year',
    'filesize': 'File Size ↓',
    'filesizeA': 'File Size ↑',
  };
}

/// Localized sort order names
Map<String, String> getOrderDisplayNames(String locale) {
  if (locale.startsWith('zh')) {
    return {
      'default': '默认顺序',
      'popular': '热度',
      'bestmatch': '匹配度',
      'title': '书名',
      'date': '上传日期',
      'year': '出版日期',
    };
  }
  return {
    'default': 'Default',
    'popular': 'Popular',
    'bestmatch': 'Best Match',
    'title': 'Title',
    'date': 'Upload Date',
    'year': 'Publish Year',
  };
}

/// File extension options
const searchExtensions = {
  'all': null,
  'pdf': 'pdf',
  'epub': 'epub',
  'mobi': 'mobi',
  'txt': 'txt',
  'azw': 'azw',
  'azw3': 'azw3',
};

/// Localized extension names
Map<String, String> getExtensionDisplayNames(String locale) {
  if (locale.startsWith('zh')) {
    return {
      'all': '所有格式',
      'pdf': 'PDF',
      'epub': 'EPUB',
      'mobi': 'MOBI',
      'txt': 'TXT',
      'azw': 'AZW',
      'azw3': 'AZW3',
    };
  }
  return {
    'all': 'All Formats',
    'pdf': 'PDF',
    'epub': 'EPUB',
    'mobi': 'MOBI',
    'txt': 'TXT',
    'azw': 'AZW',
    'azw3': 'AZW3',
  };
}
