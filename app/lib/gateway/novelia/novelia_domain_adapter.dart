import '../../core/model/reader_models.dart';
import '../../features/discover/catalog_models.dart';
import 'novelia_gateway.dart';
import 'novelia_reader_adapter.dart';

class NoveliaDomainMappingException implements Exception {
  const NoveliaDomainMappingException(this.message);

  final String message;

  @override
  String toString() => 'NoveliaDomainMappingException($message)';
}

class NoveliaRestrictedContentException extends NoveliaDomainMappingException {
  const NoveliaRestrictedContentException(super.message);
}

/// A one-based comment page whose total item count is deliberately absent.
///
/// Novelia's anonymous response exposes a total page count, but not a total
/// comment count. Keeping that omission explicit avoids presenting an estimate
/// as service data.
class NoveliaCommentSlice {
  const NoveliaCommentSlice({
    required this.pageNumber,
    required this.totalPages,
    required this.comments,
  });

  final int pageNumber;
  final int totalPages;
  final List<NovelComment> comments;
}

/// Maps Novelia transport DTOs into the app's catalog and reader semantics.
class NoveliaDomainAdapter {
  const NoveliaDomainAdapter({
    this.readerAdapter = const NoveliaReaderAdapter(),
  });

  static const hiddenCommentBody = '该评论已隐藏';
  static const defaultSectionTitle = '目录';

  final NoveliaReaderAdapter readerAdapter;

  List<CatalogNovel> mapGeneralOutlines(
    Iterable<NoveliaNovelOutline> outlines,
  ) {
    return [
      for (final outline in outlines)
        if (!isRestrictedAttentions(outline.attentions)) mapOutline(outline),
    ];
  }

  CatalogNovel mapOutline(
    NoveliaNovelOutline outline, {
    bool allowRestricted = false,
  }) {
    _requireAllowed(
      outline.attentions,
      outline.key,
      allowRestricted: allowRestricted,
    );
    _validateCoverage(
      totalChapters: outline.totalChapters,
      youdaoChapters: outline.youdaoChapters,
      gptChapters: outline.gptChapters,
      sakuraChapters: outline.sakuraChapters,
    );

    return CatalogNovel(
      id: outline.key.stableId,
      chineseTitle: outline.chineseTitle ?? outline.japaneseTitle,
      japaneseTitle: outline.japaneseTitle,
      source: providerLabel(outline.key.providerId),
      publicationState: publicationState(outline.publicationType),
      updatedAt: outline.updatedAt,
      tags: _tags(outline.attentions, outline.keywords),
      translationCoverage: _coverage(
        totalChapters: outline.totalChapters,
        youdaoChapters: outline.youdaoChapters,
        gptChapters: outline.gptChapters,
        sakuraChapters: outline.sakuraChapters,
      ),
      declaredChapterCount: outline.totalChapters,
      originalUrl: originalUri(outline.key),
    );
  }

  CatalogNovel mapDetails(
    NoveliaNovelDetails details, {
    Iterable<NoveliaChapterPayload> chapterPayloads = const [],
    List<NovelComment> comments = const [],
    bool allowRestricted = false,
  }) {
    _requireAllowed(
      details.attentions,
      details.key,
      allowRestricted: allowRestricted,
    );
    _validateNonnegative('points', details.points);
    _validateNonnegative('totalCharacters', details.totalCharacters);
    _validateNonnegative('visited', details.visited);
    _validateCoverage(
      totalChapters: details.originalChapters,
      youdaoChapters: details.youdaoChapters,
      gptChapters: details.gptChapters,
      sakuraChapters: details.sakuraChapters,
    );

    final mappedToc = _mapToc(details, chapterPayloads);
    final author = details.authors.map((author) => author.name).join('、');

    return CatalogNovel(
      id: details.key.stableId,
      chineseTitle: details.chineseTitle ?? details.japaneseTitle,
      japaneseTitle: details.japaneseTitle,
      author: author.isEmpty ? null : author,
      source: providerLabel(details.key.providerId),
      publicationState: publicationState(details.publicationType),
      wordCount: details.totalCharacters,
      updatedAt: details.syncedAt,
      tags: _tags(details.attentions, details.keywords),
      synopsis: details.chineseIntroduction ?? details.japaneseIntroduction,
      points: details.points,
      views: details.visited,
      translationCoverage: _coverage(
        totalChapters: details.originalChapters,
        youdaoChapters: details.youdaoChapters,
        gptChapters: details.gptChapters,
        sakuraChapters: details.sakuraChapters,
      ),
      readerNovel: ReaderNovel(
        id: details.key.stableId,
        chineseTitle: details.chineseTitle ?? details.japaneseTitle,
        japaneseTitle: details.japaneseTitle,
        author: author,
        chapters: mappedToc.chapters,
      ),
      declaredChapterCount: details.originalChapters,
      chapterSections: mappedToc.sections,
      comments: comments,
      originalUrl: originalUri(details.key),
    );
  }

  NoveliaCommentSlice mapCommentPage(
    NoveliaPage<NoveliaComment> page, {
    required int requestedPageNumber,
  }) {
    if (requestedPageNumber < 1) {
      throw ArgumentError.value(
        requestedPageNumber,
        'requestedPageNumber',
        'Must be one-based and positive.',
      );
    }
    if (page.pageCount < 0 ||
        (page.pageCount > 0 && requestedPageNumber > page.pageCount)) {
      throw const NoveliaDomainMappingException(
        'The comment page metadata is inconsistent.',
      );
    }
    return NoveliaCommentSlice(
      pageNumber: requestedPageNumber,
      totalPages: page.pageCount,
      comments: page.items.map(mapComment).toList(growable: false),
    );
  }

  NovelComment mapComment(NoveliaComment comment) {
    return NovelComment(
      id: comment.id,
      author: comment.username,
      body: comment.hidden ? hiddenCommentBody : comment.content,
      createdAt: comment.createdAt,
      replies: [
        for (final reply in comment.replies)
          NovelCommentReply(
            id: reply.id,
            author: reply.username,
            body: reply.hidden ? hiddenCommentBody : reply.content,
            createdAt: reply.createdAt,
          ),
      ],
    );
  }

  bool isRestrictedAttentions(Iterable<String> attentions) {
    return attentions.any((value) => value.trim().toUpperCase() == 'R18');
  }

  bool isRestrictedCatalogNovel(CatalogNovel novel) {
    return isRestrictedAttentions(novel.tags);
  }

  String providerLabel(String providerId) {
    return switch (providerId) {
      'kakuyomu' => 'Kakuyomu',
      'syosetu' => 'Syosetu',
      'novelup' => 'Novelup',
      'hameln' => 'Hameln',
      'pixiv' => 'Pixiv',
      'alphapolis' => 'Alphapolis',
      _ => throw NoveliaDomainMappingException(
        'Unsupported Novelia provider: $providerId.',
      ),
    };
  }

  NovelPublicationState publicationState(String? value) {
    return switch (value) {
      '连载中' || '连载' => NovelPublicationState.ongoing,
      '已完结' || '完结' => NovelPublicationState.completed,
      '短篇' => NovelPublicationState.shortStory,
      _ => NovelPublicationState.unknown,
    };
  }

  NoveliaNovelKey? keyFromStableId(String stableId) {
    final separator = stableId.indexOf('/');
    if (separator <= 0 ||
        separator == stableId.length - 1 ||
        stableId.indexOf('/', separator + 1) != -1) {
      return null;
    }
    final providerId = stableId.substring(0, separator);
    final novelId = stableId.substring(separator + 1);
    if (!defaultGeneralCatalogProviders.contains(providerId)) return null;
    return NoveliaNovelKey(providerId: providerId, novelId: novelId);
  }

  /// Returns a provider URL only for an identifier shape verified by that
  /// provider's public URL scheme.
  Uri? originalUri(NoveliaNovelKey key) {
    final id = key.novelId;
    return switch (key.providerId) {
      'kakuyomu' when _digits.hasMatch(id) => Uri.https(
        'kakuyomu.jp',
        '/works/$id',
      ),
      'syosetu' when _lettersAndDigits.hasMatch(id) => Uri.https(
        'ncode.syosetu.com',
        '/$id',
      ),
      'novelup' when _digits.hasMatch(id) => Uri.https(
        'novelup.plus',
        '/story/$id',
      ),
      'hameln' when _digits.hasMatch(id) => Uri.https(
        'syosetu.org',
        '/novel/$id',
      ),
      'pixiv' when _digits.hasMatch(id) => Uri.https(
        'www.pixiv.net',
        '/novel/series/$id',
      ),
      'pixiv' when _pixivShortId.hasMatch(id) => Uri.https(
        'www.pixiv.net',
        '/novel/show.php',
        {'id': id.substring(1)},
      ),
      'alphapolis' when _alphapolisId.hasMatch(id) => _alphapolisUri(id),
      _ => null,
    };
  }

  _MappedToc _mapToc(
    NoveliaNovelDetails details,
    Iterable<NoveliaChapterPayload> chapterPayloads,
  ) {
    final payloadById = <String, NoveliaChapterPayload>{};
    for (final payload in chapterPayloads) {
      if (payload.key != details.key) {
        throw const NoveliaDomainMappingException(
          'A chapter payload belongs to a different novel.',
        );
      }
      if (payloadById.containsKey(payload.chapterId)) {
        throw NoveliaDomainMappingException(
          'Duplicate chapter payload: ${payload.chapterId}.',
        );
      }
      payloadById[payload.chapterId] = payload;
    }

    final tocIds = <String>{};
    for (final entry in details.toc) {
      final chapterId = entry.chapterId;
      if (chapterId != null && !tocIds.add(chapterId)) {
        throw NoveliaDomainMappingException(
          'The table of contents repeats chapter $chapterId.',
        );
      }
    }
    for (final chapterId in payloadById.keys) {
      if (!tocIds.contains(chapterId)) {
        throw NoveliaDomainMappingException(
          'Chapter $chapterId is absent from the table of contents.',
        );
      }
    }

    final chapters = <NovelChapter>[];
    final sections = <CatalogChapterSection>[];
    var sectionTitle = defaultSectionTitle;
    var sectionChapterIds = <String>[];

    void flushSection() {
      if (sectionChapterIds.isEmpty) return;
      sections.add(
        CatalogChapterSection(
          title: sectionTitle,
          chapterIds: List.unmodifiable(sectionChapterIds),
        ),
      );
      sectionChapterIds = <String>[];
    }

    for (final entry in details.toc) {
      final chapterId = entry.chapterId;
      if (chapterId == null) {
        flushSection();
        sectionTitle = entry.chineseTitle ?? entry.japaneseTitle;
        continue;
      }
      final index = chapters.length + 1;
      final payload = payloadById[chapterId];
      chapters.add(
        payload == null
            ? NovelChapter(
                id: chapterId,
                index: index,
                chineseTitle: entry.chineseTitle ?? entry.japaneseTitle,
                japaneseTitle: entry.japaneseTitle,
                publishedAt: entry.createdAt,
                blocks: const [],
              )
            : readerAdapter.buildSingleChapter(
                payload: payload,
                tocEntry: entry,
                index: index,
              ),
      );
      sectionChapterIds.add(chapterId);
    }
    flushSection();

    return _MappedToc(chapters: chapters, sections: sections);
  }

  static List<String> _tags(
    Iterable<String> attentions,
    Iterable<String> keywords,
  ) {
    final seen = <String>{};
    return [
      for (final tag in [...attentions, ...keywords])
        if (seen.add(tag)) tag,
    ];
  }

  static List<TranslationCoverage> _coverage({
    required int totalChapters,
    required int youdaoChapters,
    required int gptChapters,
    required int sakuraChapters,
  }) {
    return [
      TranslationCoverage(
        source: TranslationSource.youdao.label,
        translatedChapters: youdaoChapters,
        totalChapters: totalChapters,
      ),
      TranslationCoverage(
        source: TranslationSource.gpt.label,
        translatedChapters: gptChapters,
        totalChapters: totalChapters,
      ),
      TranslationCoverage(
        source: TranslationSource.sakura.label,
        translatedChapters: sakuraChapters,
        totalChapters: totalChapters,
      ),
    ];
  }

  static void _validateCoverage({
    required int totalChapters,
    required int youdaoChapters,
    required int gptChapters,
    required int sakuraChapters,
  }) {
    if (totalChapters < 0) {
      throw const NoveliaDomainMappingException(
        'The service returned a negative chapter count.',
      );
    }
    for (final count in [youdaoChapters, gptChapters, sakuraChapters]) {
      if (count < 0 || count > totalChapters) {
        throw const NoveliaDomainMappingException(
          'The service returned inconsistent translation coverage.',
        );
      }
    }
  }

  static void _validateNonnegative(String field, int? value) {
    if (value != null && value < 0) {
      throw NoveliaDomainMappingException(
        'The service returned a negative $field value.',
      );
    }
  }

  void _requireAllowed(
    Iterable<String> attentions,
    NoveliaNovelKey key, {
    required bool allowRestricted,
  }) {
    if (!allowRestricted && isRestrictedAttentions(attentions)) {
      throw NoveliaRestrictedContentException(
        'Restricted novel ${key.stableId} was rejected.',
      );
    }
  }

  static Uri _alphapolisUri(String id) {
    final separator = id.indexOf('-');
    return Uri.https(
      'www.alphapolis.co.jp',
      '/novel/${id.substring(0, separator)}/${id.substring(separator + 1)}',
    );
  }

  static final _digits = RegExp(r'^\d+$');
  static final _lettersAndDigits = RegExp(r'^[A-Za-z0-9]+$');
  static final _pixivShortId = RegExp(r'^s\d+$');
  static final _alphapolisId = RegExp(r'^\d+-\d+$');
}

class _MappedToc {
  const _MappedToc({required this.chapters, required this.sections});

  final List<NovelChapter> chapters;
  final List<CatalogChapterSection> sections;
}
