import 'dart:async';

/// The providers currently exposed by Novelia's signed-out Web Novel catalog.
const defaultGeneralCatalogProviders = <String>[
  'kakuyomu',
  'syosetu',
  'novelup',
  'hameln',
  'pixiv',
  'alphapolis',
];

enum NoveliaGatewayFailureKind {
  authenticationRequired,
  forbidden,
  notFound,
  timeout,
  network,
  invalidResponse,
  server,
}

class NoveliaGatewayException implements Exception {
  const NoveliaGatewayException(this.kind, this.message, {this.statusCode});

  final NoveliaGatewayFailureKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'NoveliaGatewayException($kind, $message)';
}

class NoveliaNovelKey {
  const NoveliaNovelKey({required this.providerId, required this.novelId});

  final String providerId;
  final String novelId;

  String get stableId => '$providerId/$novelId';
  String get commentSite => 'web-$providerId-$novelId';

  @override
  bool operator ==(Object other) =>
      other is NoveliaNovelKey &&
      other.providerId == providerId &&
      other.novelId == novelId;

  @override
  int get hashCode => Object.hash(providerId, novelId);
}

class NoveliaPage<T> {
  const NoveliaPage({required this.items, required this.pageCount});

  final List<T> items;
  final int pageCount;
}

/// Query values are kept as service codes inside the gateway boundary.
///
/// Signed-out requests must stay at [contentLevel] 1. An unconstrained level 0
/// request is intentionally rejected by the service.
class NoveliaCatalogQuery {
  const NoveliaCatalogQuery({
    this.page = 0,
    this.pageSize = 20,
    this.search = '',
    this.providers = defaultGeneralCatalogProviders,
    this.publicationType = 0,
    this.contentLevel = 1,
    this.translationFilter = 0,
    this.sort = 0,
  });

  final int page;
  final int pageSize;
  final String search;
  final List<String> providers;
  final int publicationType;
  final int contentLevel;
  final int translationFilter;
  final int sort;

  Map<String, String> toQueryParameters() => {
    'page': '$page',
    'pageSize': '$pageSize',
    'query': search,
    'provider': providers.join(','),
    'type': '$publicationType',
    'level': '$contentLevel',
    'translate': '$translationFilter',
    'sort': '$sort',
  };
}

class NoveliaRankingQuery {
  const NoveliaRankingQuery({
    required this.providerId,
    required this.parameters,
  });

  factory NoveliaRankingQuery.syosetu({
    String type = '综合',
    String range = '总计',
    String status = '全部',
    String? genre,
    int page = 1,
  }) {
    return NoveliaRankingQuery(
      providerId: 'syosetu',
      parameters: {
        'type': type,
        'range': range,
        'status': status,
        'genre': ?genre,
        'page': '$page',
      },
    );
  }

  factory NoveliaRankingQuery.kakuyomu({
    required String genre,
    required String range,
    String status = '全部',
  }) {
    return NoveliaRankingQuery(
      providerId: 'kakuyomu',
      parameters: {'genre': genre, 'range': range, 'status': status},
    );
  }

  final String providerId;
  final Map<String, String> parameters;
}

class NoveliaNovelOutline {
  const NoveliaNovelOutline({
    required this.key,
    required this.japaneseTitle,
    required this.chineseTitle,
    required this.publicationType,
    required this.extra,
    required this.attentions,
    required this.keywords,
    required this.totalChapters,
    required this.originalChapters,
    required this.baiduChapters,
    required this.youdaoChapters,
    required this.gptChapters,
    required this.sakuraChapters,
    required this.updatedAt,
    this.favoriteFolderId,
  });

  final NoveliaNovelKey key;
  final String japaneseTitle;
  final String? chineseTitle;
  final String? publicationType;
  final String? extra;
  final List<String> attentions;
  final List<String> keywords;
  final int totalChapters;
  final int originalChapters;
  final int baiduChapters;
  final int youdaoChapters;
  final int gptChapters;
  final int sakuraChapters;
  final DateTime? updatedAt;
  final String? favoriteFolderId;
}

class NoveliaAuthor {
  const NoveliaAuthor({required this.name, this.link});

  final String name;
  final Uri? link;
}

class NoveliaTocEntry {
  const NoveliaTocEntry({
    required this.japaneseTitle,
    required this.chineseTitle,
    required this.chapterId,
    required this.createdAt,
  });

  final String japaneseTitle;
  final String? chineseTitle;
  final String? chapterId;
  final DateTime? createdAt;

  bool get isSection => chapterId == null;
}

class NoveliaNovelDetails {
  const NoveliaNovelDetails({
    required this.key,
    required this.japaneseTitle,
    required this.chineseTitle,
    required this.authors,
    required this.publicationType,
    required this.attentions,
    required this.keywords,
    required this.points,
    required this.totalCharacters,
    required this.japaneseIntroduction,
    required this.chineseIntroduction,
    required this.toc,
    required this.visited,
    required this.syncedAt,
    required this.originalChapters,
    required this.baiduChapters,
    required this.youdaoChapters,
    required this.gptChapters,
    required this.sakuraChapters,
    this.favoriteFolderId,
  });

  final NoveliaNovelKey key;
  final String japaneseTitle;
  final String? chineseTitle;
  final List<NoveliaAuthor> authors;
  final String? publicationType;
  final List<String> attentions;
  final List<String> keywords;
  final int? points;
  final int? totalCharacters;
  final String japaneseIntroduction;
  final String? chineseIntroduction;
  final List<NoveliaTocEntry> toc;
  final int? visited;
  final DateTime? syncedAt;
  final int originalChapters;
  final int baiduChapters;
  final int youdaoChapters;
  final int gptChapters;
  final int sakuraChapters;
  final String? favoriteFolderId;
}

class NoveliaChapterPayload {
  const NoveliaChapterPayload({
    required this.key,
    required this.chapterId,
    required this.japaneseTitle,
    required this.chineseTitle,
    required this.novelJapaneseTitle,
    required this.novelChineseTitle,
    required this.previousChapterId,
    required this.nextChapterId,
    required this.originalParagraphs,
    required this.baiduParagraphs,
    required this.youdaoParagraphs,
    required this.gptParagraphs,
    required this.sakuraParagraphs,
  });

  final NoveliaNovelKey key;
  final String chapterId;
  final String japaneseTitle;
  final String? chineseTitle;
  final String? novelJapaneseTitle;
  final String? novelChineseTitle;
  final String? previousChapterId;
  final String? nextChapterId;
  final List<String> originalParagraphs;
  final List<String> baiduParagraphs;
  final List<String> youdaoParagraphs;
  final List<String> gptParagraphs;
  final List<String> sakuraParagraphs;
}

class NoveliaComment {
  const NoveliaComment({
    required this.id,
    required this.username,
    required this.content,
    required this.hidden,
    required this.createdAt,
    required this.replyCount,
    required this.replies,
  });

  final String id;
  final String username;
  final String content;
  final bool hidden;
  final DateTime createdAt;
  final int replyCount;
  final List<NoveliaComment> replies;
}

abstract interface class NoveliaGateway {
  Future<NoveliaPage<NoveliaNovelOutline>> listNovels(
    NoveliaCatalogQuery query,
  );

  Future<NoveliaPage<NoveliaNovelOutline>> listRankings(
    NoveliaRankingQuery query,
  );

  Future<NoveliaNovelDetails> getNovel(NoveliaNovelKey key);

  Future<NoveliaChapterPayload> getChapter(
    NoveliaNovelKey key,
    String chapterId,
  );

  Future<NoveliaPage<NoveliaComment>> listComments(
    NoveliaNovelKey key, {
    int page = 0,
    int pageSize = 10,
  });
}

typedef NoveliaAccessTokenProvider = FutureOr<String?> Function();
