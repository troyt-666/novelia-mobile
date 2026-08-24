import 'dart:typed_data';

import 'novelia_gateway.dart';

enum WenkuTranslationProvider { sakura, gpt, youdao, baidu }

extension WenkuTranslationProviderLabel on WenkuTranslationProvider {
  String get serviceCode => name;

  String get label => switch (this) {
    WenkuTranslationProvider.sakura => 'Sakura',
    WenkuTranslationProvider.gpt => 'GPT',
    WenkuTranslationProvider.youdao => '有道',
    WenkuTranslationProvider.baidu => '百度',
  };
}

enum WenkuBilingualOrder { chineseFirst, japaneseFirst }

extension WenkuBilingualOrderCode on WenkuBilingualOrder {
  String get serviceCode => switch (this) {
    WenkuBilingualOrder.chineseFirst => 'zh-jp',
    WenkuBilingualOrder.japaneseFirst => 'jp-zh',
  };

  String get label => switch (this) {
    WenkuBilingualOrder.chineseFirst => '中文在前',
    WenkuBilingualOrder.japaneseFirst => '日文在前',
  };
}

enum WenkuCatalogLevel {
  all(0, '全部小说'),
  lightNovel(1, '轻小说'),
  lightLiterature(2, '轻文学'),
  literature(3, '文学'),
  nonfiction(4, '非小说'),
  r18Male(5, 'R18男性向'),
  r18Female(6, 'R18女性向');

  const WenkuCatalogLevel(this.serviceCode, this.label);

  final int serviceCode;
  final String label;
}

class WenkuCatalogQuery {
  const WenkuCatalogQuery({
    this.page = 0,
    this.pageSize = 20,
    this.search = '',
    this.level = WenkuCatalogLevel.all,
  });

  final int page;
  final int pageSize;
  final String search;

  final WenkuCatalogLevel level;

  Map<String, String> toQueryParameters() => {
    'page': '$page',
    'pageSize': '$pageSize',
    'query': search,
    'level': '${level.serviceCode}',
  };
}

class WenkuNovelSummary {
  const WenkuNovelSummary({
    required this.id,
    required this.japaneseTitle,
    required this.chineseTitle,
    required this.coverUri,
  });

  final String id;
  final String japaneseTitle;
  final String chineseTitle;
  final Uri? coverUri;
}

class WenkuPublishedVolume {
  const WenkuPublishedVolume({
    required this.asin,
    required this.japaneseTitle,
    required this.chineseTitle,
    required this.coverUri,
    required this.publishedAt,
  });

  final String asin;
  final String japaneseTitle;
  final String? chineseTitle;
  final Uri? coverUri;
  final DateTime? publishedAt;
}

class WenkuEpubVolume {
  const WenkuEpubVolume({
    required this.volumeId,
    required this.totalParagraphs,
    required this.translationCounts,
  });

  final String volumeId;
  final int totalParagraphs;
  final Map<WenkuTranslationProvider, int> translationCounts;

  int coverageFor(WenkuTranslationProvider provider) =>
      translationCounts[provider] ?? 0;

  double coverageRatioFor(WenkuTranslationProvider provider) =>
      totalParagraphs <= 0
      ? 0
      : (coverageFor(provider) / totalParagraphs).clamp(0, 1);

  List<WenkuTranslationProvider> get availableProviders => [
    for (final provider in WenkuTranslationProvider.values)
      if (coverageFor(provider) > 0) provider,
  ];
}

class WenkuNovelDetails {
  const WenkuNovelDetails({
    required this.id,
    required this.japaneseTitle,
    required this.chineseTitle,
    required this.coverUri,
    required this.authors,
    required this.artists,
    required this.keywords,
    required this.publisher,
    required this.imprint,
    required this.level,
    required this.introduction,
    required this.publishedVolumes,
    required this.japaneseEpubs,
    required this.chineseEpubIds,
  });

  final String id;
  final String japaneseTitle;
  final String chineseTitle;
  final Uri? coverUri;
  final List<String> authors;
  final List<String> artists;
  final List<String> keywords;
  final String? publisher;
  final String? imprint;
  final String level;
  final String introduction;
  final List<WenkuPublishedVolume> publishedVolumes;
  final List<WenkuEpubVolume> japaneseEpubs;
  final List<String> chineseEpubIds;
}

class WenkuEpubRequest {
  const WenkuEpubRequest({
    required this.novelId,
    required this.volumeId,
    required this.order,
    required this.providers,
    required this.filename,
  });

  final String novelId;
  final String volumeId;
  final WenkuBilingualOrder order;
  final List<WenkuTranslationProvider> providers;
  final String filename;
}

class WenkuEpubDownloadCancelledException implements Exception {
  const WenkuEpubDownloadCancelledException();
}

class WenkuEpubDownloadCancellationToken {
  final Set<void Function()> _listeners = {};
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (_isCancelled) throw const WenkuEpubDownloadCancelledException();
  }

  void Function() addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

abstract interface class NoveliaWenkuGateway {
  Future<NoveliaPage<WenkuNovelSummary>> listNovels(WenkuCatalogQuery query);

  Future<WenkuNovelDetails> getNovel(String novelId);

  Future<Uint8List> downloadEpub(
    WenkuEpubRequest request, {
    void Function(int bytesReceived, int? totalBytes)? onReceiveProgress,
    WenkuEpubDownloadCancellationToken? cancellationToken,
  });
}
