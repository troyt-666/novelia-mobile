import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_domain_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';

void main() {
  const adapter = NoveliaDomainAdapter();
  const key = NoveliaNovelKey(providerId: 'syosetu', novelId: 'n8439ed');

  group('NoveliaDomainAdapter', () {
    test('maps truthful outline metadata without synthetic chapters', () {
      final novel = adapter.mapOutline(_outline());

      expect(novel.id, 'syosetu/n8439ed');
      expect(novel.source, 'Syosetu');
      expect(novel.publicationState, NovelPublicationState.ongoing);
      expect(novel.declaredChapterCount, 12);
      expect(novel.chapterCount, 12);
      expect(novel.readerNovel, isNull);
      expect(novel.translationCoverage, [
        isA<TranslationCoverage>()
            .having((value) => value.source, 'source', '有道')
            .having((value) => value.translatedChapters, 'translated', 10)
            .having((value) => value.totalChapters, 'total', 12),
        isA<TranslationCoverage>()
            .having((value) => value.source, 'source', 'GPT')
            .having((value) => value.translatedChapters, 'translated', 8)
            .having((value) => value.totalChapters, 'total', 12),
        isA<TranslationCoverage>()
            .having((value) => value.source, 'source', 'Sakura')
            .having((value) => value.translatedChapters, 'translated', 7)
            .having((value) => value.totalChapters, 'total', 12),
      ]);
      expect(novel.originalUrl, Uri.parse('https://ncode.syosetu.com/n8439ed'));
    });

    test('preserves an omitted publication type as unknown', () {
      final novel = adapter.mapOutline(_outline(publicationType: null));
      const cacheAdapter = NoveliaContentCacheAdapter();
      final cached = cacheAdapter.cacheOutline(
        _outline(publicationType: null),
        fetchedAt: DateTime.utc(2026, 8, 17),
      );

      expect(novel.publicationState, NovelPublicationState.unknown);
      expect(cached.publicationState.name, 'unknown');
      expect(
        cacheAdapter.restoreOutline(cached).publicationState,
        NovelPublicationState.unknown,
      );
    });

    test('builds a sectioned metadata-only TOC from service chapter IDs', () {
      final novel = adapter.mapDetails(_details());

      expect(novel.declaredChapterCount, 2);
      expect(novel.readerNovel!.chapters.map((chapter) => chapter.id), [
        'c1',
        'c2',
      ]);
      expect(
        novel.readerNovel!.chapters.every((chapter) => chapter.blocks.isEmpty),
        isTrue,
      );
      expect(novel.chapterSections.map((section) => section.title), [
        '第一卷',
        '第二卷',
      ]);
      expect(novel.chapterSections.first.chapterIds, ['c1']);
      expect(novel.chapterSections.last.chapterIds, ['c2']);
    });

    test('filters R18 outlines and rejects R18 details', () {
      expect(
        adapter.mapGeneralOutlines([
          _outline(attentions: const ['R18']),
        ]),
        isEmpty,
      );
      expect(
        () => adapter.mapDetails(_details(attentions: const ['r18'])),
        throwsA(isA<NoveliaRestrictedContentException>()),
      );
    });

    test('redacts hidden top-level comments and replies', () {
      final page = adapter.mapCommentPage(
        NoveliaPage(
          pageCount: 3,
          items: [
            NoveliaComment(
              id: 'comment',
              username: 'reader',
              content: 'must not leak',
              hidden: true,
              createdAt: DateTime.utc(2026, 8, 17),
              replyCount: 1,
              replies: [
                NoveliaComment(
                  id: 'reply',
                  username: 'reply-reader',
                  content: 'also secret',
                  hidden: true,
                  createdAt: DateTime.utc(2026, 8, 17, 1),
                  replyCount: 0,
                  replies: const [],
                ),
              ],
            ),
          ],
        ),
        requestedPageNumber: 2,
      );

      expect(page.pageNumber, 2);
      expect(page.totalPages, 3);
      expect(page.comments.single.body, NoveliaDomainAdapter.hiddenCommentBody);
      expect(
        page.comments.single.replies.single.body,
        NoveliaDomainAdapter.hiddenCommentBody,
      );
      expect(page.comments.single.body, isNot(contains('leak')));
    });

    test('derives original URLs only for verified provider ID shapes', () {
      expect(
        adapter.originalUri(
          const NoveliaNovelKey(providerId: 'kakuyomu', novelId: '12345'),
        ),
        Uri.parse('https://kakuyomu.jp/works/12345'),
      );
      expect(
        adapter.originalUri(
          const NoveliaNovelKey(providerId: 'novelup', novelId: '77'),
        ),
        Uri.parse('https://novelup.plus/story/77'),
      );
      expect(
        adapter.originalUri(
          const NoveliaNovelKey(providerId: 'hameln', novelId: '88'),
        ),
        Uri.parse('https://syosetu.org/novel/88'),
      );
      expect(
        adapter.originalUri(
          const NoveliaNovelKey(providerId: 'pixiv', novelId: '99'),
        ),
        Uri.parse('https://www.pixiv.net/novel/series/99'),
      );
      expect(
        adapter.originalUri(
          const NoveliaNovelKey(providerId: 'pixiv', novelId: 's100'),
        ),
        Uri.parse('https://www.pixiv.net/novel/show.php?id=100'),
      );
      expect(
        adapter.originalUri(
          const NoveliaNovelKey(providerId: 'alphapolis', novelId: '10-20'),
        ),
        Uri.parse('https://www.alphapolis.co.jp/novel/10/20'),
      );
      expect(
        adapter.originalUri(
          const NoveliaNovelKey(providerId: 'kakuyomu', novelId: '../unsafe'),
        ),
        isNull,
      );
    });
  });

  test('cache round-trip preserves empties and rejects mismatched source', () {
    const cacheAdapter = NoveliaContentCacheAdapter();
    final payload = NoveliaChapterPayload(
      key: key,
      chapterId: 'c1',
      japaneseTitle: '第一話',
      chineseTitle: '第一章',
      novelJapaneseTitle: '作品',
      novelChineseTitle: '作品',
      previousChapterId: null,
      nextChapterId: 'c2',
      originalParagraphs: const ['一', '', '三'],
      baiduParagraphs: const [],
      youdaoParagraphs: const ['甲', '', '丙'],
      gptParagraphs: const [],
      sakuraParagraphs: const ['甲'],
    );
    final cached = cacheAdapter.cacheChapter(
      payload,
      metadata: NovelChapter(
        id: 'c1',
        index: 1,
        chineseTitle: '第一章',
        japaneseTitle: '第一話',
        publishedAt: DateTime.utc(2026, 8, 17),
        blocks: const [],
      ),
      fetchedAt: DateTime.utc(2026, 8, 17),
    );

    final restored = cacheAdapter.restoreChapter(cached);

    expect(cached.revision, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(cached.id, endsWith(cached.revision!));
    expect(restored.blocks.map((block) => block.japanese), ['一', '', '三']);
    expect(
      restored.translationState(TranslationSource.youdao),
      TranslationState.complete,
    );
    expect(restored.blocks[1].translations[TranslationSource.youdao], '');
    expect(
      restored.translationState(TranslationSource.sakura),
      TranslationState.invalid,
    );
    expect(
      restored.blocks.every(
        (block) => !block.translations.containsKey(TranslationSource.sakura),
      ),
      isTrue,
    );
  });

  test('restore fails closed when a SHA-256 revision does not match', () {
    const cacheAdapter = NoveliaContentCacheAdapter();
    final cached = cacheAdapter.cacheChapter(
      NoveliaChapterPayload(
        key: key,
        chapterId: 'c1',
        japaneseTitle: '第一話',
        chineseTitle: '第一章',
        novelJapaneseTitle: '作品',
        novelChineseTitle: '作品',
        previousChapterId: null,
        nextChapterId: 'c2',
        originalParagraphs: const ['一'],
        baiduParagraphs: const [],
        youdaoParagraphs: const ['甲'],
        gptParagraphs: const [],
        sakuraParagraphs: const [],
      ),
      metadata: NovelChapter(
        id: 'c1',
        index: 1,
        chineseTitle: '第一章',
        japaneseTitle: '第一話',
        publishedAt: DateTime.utc(2026, 8, 17),
        blocks: const [],
      ),
      fetchedAt: DateTime.utc(2026, 8, 17),
    );

    final tampered = CachedChapterPayload(
      id: cached.id,
      novelId: cached.novelId,
      chapterId: cached.chapterId,
      index: cached.index,
      chineseTitle: cached.chineseTitle,
      japaneseTitle: cached.japaneseTitle,
      previousChapterId: cached.previousChapterId,
      nextChapterId: cached.nextChapterId,
      publishedAt: cached.publishedAt,
      japaneseBlocks: const ['被篡改'],
      translations: cached.translations,
      fetchedAt: cached.fetchedAt,
      revision: cached.revision,
      etag: cached.etag,
    );

    expect(
      () => cacheAdapter.restoreChapter(tampered),
      throwsA(isA<NoveliaDomainMappingException>()),
    );
  });

  test('restore skips checksum for short fixture revisions', () {
    const cacheAdapter = NoveliaContentCacheAdapter();
    final fixture = CachedChapterPayload(
      id: 'payload-r1',
      novelId: key.stableId,
      chapterId: 'c1',
      index: 1,
      chineseTitle: '第一章',
      japaneseTitle: '第一話',
      previousChapterId: null,
      nextChapterId: null,
      publishedAt: DateTime.utc(2026, 8, 17),
      japaneseBlocks: const ['一'],
      translations: {
        TranslationSource.youdao: CachedChapterTranslation(
          availability: TranslationAvailability.complete,
          blocks: const ['甲'],
        ),
      },
      fetchedAt: DateTime.utc(2026, 8, 17),
      revision: 'r1',
    );

    expect(cacheAdapter.restoreChapter(fixture).id, 'c1');
  });
}

NoveliaNovelOutline _outline({
  List<String> attentions = const ['一般向'],
  String? publicationType = '连载中',
}) {
  return NoveliaNovelOutline(
    key: const NoveliaNovelKey(providerId: 'syosetu', novelId: 'n8439ed'),
    japaneseTitle: '夜の列車',
    chineseTitle: '夜行列车',
    publicationType: publicationType,
    extra: null,
    attentions: attentions,
    keywords: const ['幻想'],
    totalChapters: 12,
    originalChapters: 12,
    baiduChapters: 4,
    youdaoChapters: 10,
    gptChapters: 8,
    sakuraChapters: 7,
    updatedAt: DateTime.utc(2026, 8, 17),
  );
}

NoveliaNovelDetails _details({List<String> attentions = const ['一般向']}) {
  return NoveliaNovelDetails(
    key: const NoveliaNovelKey(providerId: 'syosetu', novelId: 'n8439ed'),
    japaneseTitle: '夜の列車',
    chineseTitle: '夜行列车',
    authors: const [NoveliaAuthor(name: '作者')],
    publicationType: '已完结',
    attentions: attentions,
    keywords: const ['幻想'],
    points: 42,
    totalCharacters: 1000,
    japaneseIntroduction: '紹介',
    chineseIntroduction: '简介',
    toc: [
      const NoveliaTocEntry(
        japaneseTitle: '第一巻',
        chineseTitle: '第一卷',
        chapterId: null,
        createdAt: null,
      ),
      NoveliaTocEntry(
        japaneseTitle: '第一話',
        chineseTitle: '第一章',
        chapterId: 'c1',
        createdAt: DateTime.utc(2026, 8, 16),
      ),
      const NoveliaTocEntry(
        japaneseTitle: '第二巻',
        chineseTitle: '第二卷',
        chapterId: null,
        createdAt: null,
      ),
      NoveliaTocEntry(
        japaneseTitle: '第二話',
        chineseTitle: '第二章',
        chapterId: 'c2',
        createdAt: DateTime.utc(2026, 8, 17),
      ),
    ],
    visited: 99,
    syncedAt: DateTime.utc(2026, 8, 17),
    originalChapters: 2,
    baiduChapters: 0,
    youdaoChapters: 2,
    gptChapters: 1,
    sakuraChapters: 0,
  );
}
