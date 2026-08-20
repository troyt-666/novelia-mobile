import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/gateway/novelia/http_novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_reader_adapter.dart';
import 'package:jfzreader/core/model/reader_models.dart';

void main() {
  const codec = NoveliaJsonCodec();
  const key = NoveliaNovelKey(providerId: 'fixture', novelId: 'novel-1');

  test('signed-out catalog query is constrained to general content', () {
    const query = NoveliaCatalogQuery();

    expect(query.contentLevel, 1);
    expect(query.providers, defaultGeneralCatalogProviders);
    expect(query.toQueryParameters()['provider'], contains('syosetu'));
  });

  test('decodes a sanitized catalog page including all coverage counts', () {
    final page = codec.decodeNovelPage({
      'items': [
        {
          'providerId': 'fixture',
          'novelId': 'novel-1',
          'titleJp': '夜の列車',
          'titleZh': '夜行列车',
          'type': '连载',
          'attentions': ['一般向'],
          'keywords': ['幻想'],
          'total': 12,
          'jp': 12,
          'baidu': 4,
          'youdao': 10,
          'gpt': 8,
          'sakura': 7,
          'favored': 'folder-1',
          'updateAt': 1_787_000_000,
        },
      ],
      'pageNumber': 3,
    });

    expect(page.pageCount, 3);
    expect(page.items.single.key, key);
    expect(page.items.single.baiduChapters, 4);
    expect(page.items.single.youdaoChapters, 10);
    expect(page.items.single.favoriteFolderId, 'folder-1');
  });

  test('decodes sectioned details without inventing chapter IDs', () {
    final novel = codec.decodeNovel(key, {
      'titleJp': '夜の列車',
      'titleZh': '夜行列车',
      'authors': [
        {'name': '作者', 'link': 'https://example.invalid/author'},
      ],
      'type': '连载',
      'attentions': <String>[],
      'keywords': ['幻想'],
      'points': 42,
      'totalCharacters': 1000,
      'introductionJp': '紹介',
      'introductionZh': '简介',
      'toc': [
        {'titleJp': '第一部', 'titleZh': '第一部'},
        {
          'titleJp': '出発',
          'titleZh': '出发',
          'chapterId': 'c1',
          'createAt': 1_787_000_000,
        },
      ],
      'visited': 99,
      'syncAt': 1_787_000_100,
      'jp': 1,
      'youdao': 1,
      'gpt': 0,
      'sakura': 1,
      'favored': 'folder-1',
    });

    expect(novel.toc.first.isSection, isTrue);
    expect(novel.toc.first.chapterId, isNull);
    expect(novel.toc.last.chapterId, 'c1');
    expect(novel.toc.last.createdAt, isNotNull);
    expect(novel.baiduChapters, 0);
    expect(novel.favoriteFolderId, 'folder-1');
  });

  test('keeps independently omitted and mismatched translation arrays', () {
    final chapter = codec.decodeChapter(key, 'c1', {
      'titleJp': '出発',
      'titleZh': '出发',
      'novelTitleJp': '夜の列車',
      'novelTitleZh': '夜行列车',
      'nextId': 'c2',
      'paragraphs': ['一', '', '三'],
      'youdaoParagraphs': ['甲', '', '丙'],
      'sakuraParagraphs': ['甲'],
    });

    expect(chapter.originalParagraphs, ['一', '', '三']);
    expect(chapter.gptParagraphs, isEmpty);
    expect(chapter.sakuraParagraphs, hasLength(1));
    expect(chapter.previousChapterId, isNull);
    expect(chapter.nextChapterId, 'c2');
  });

  test('maps normalized illustration paragraphs to safe image blocks', () {
    const imageUrl =
        'https://47209.mitemin.net/userpageimage/viewimagebig/icode/i971569/';
    final chapter = const NoveliaReaderAdapter().buildSingleChapter(
      payload: NoveliaChapterPayload(
        key: key,
        chapterId: 'c1',
        japaneseTitle: '挿絵の章',
        chineseTitle: '插图章节',
        novelJapaneseTitle: '作品',
        novelChineseTitle: '作品',
        previousChapterId: null,
        nextChapterId: null,
        originalParagraphs: const ['<图片>$imageUrl'],
        baiduParagraphs: const [],
        youdaoParagraphs: const [],
        gptParagraphs: const [],
        sakuraParagraphs: const [],
      ),
    );

    expect(chapter.blocks.single.kind, AlignedBlockKind.illustration);
    expect(chapter.blocks.single.illustrationUri, Uri.parse(imageUrl));
  });

  test('decodes one bounded comment page with embedded replies', () {
    final page = codec.decodeCommentPage({
      'items': [
        {
          'id': 'comment-1',
          'user': {'username': '读者'},
          'content': '节奏很好。',
          'hidden': false,
          'createAt': 1_787_000_000,
          'numReplies': 1,
          'replies': [
            {
              'id': 'reply-1',
              'user': {'username': '另一位读者'},
              'content': '同感。',
              'hidden': false,
              'createAt': 1_787_000_010,
              'numReplies': 0,
              'replies': <Object?>[],
            },
          ],
        },
      ],
      'pageNumber': 2,
    });

    expect(key.commentSite, 'web-fixture-novel-1');
    expect(page.pageCount, 2);
    expect(page.items.single.replies.single.id, 'reply-1');
  });

  test('fails closed when an aligned source changes type', () {
    expect(
      () => codec.decodeChapter(key, 'c1', {
        'titleJp': '出発',
        'paragraphs': ['一'],
        'youdaoParagraphs': 'not-an-array',
      }),
      throwsA(
        isA<NoveliaGatewayException>().having(
          (error) => error.kind,
          'kind',
          NoveliaGatewayFailureKind.invalidResponse,
        ),
      ),
    );
  });

  test('reader adapter fails a whole mismatched translation revision', () {
    final details = codec.decodeNovel(key, {
      'titleJp': '夜の列車',
      'titleZh': '夜行列车',
      'authors': [
        {'name': '作者'},
      ],
      'attentions': <String>[],
      'keywords': <String>[],
      'introductionJp': '紹介',
      'toc': [
        {'titleJp': '出発', 'chapterId': 'c1'},
      ],
      'visited': 1,
      'syncAt': 1_787_000_000,
      'jp': 1,
      'youdao': 1,
      'gpt': 0,
      'sakura': 0,
    });
    final payload = codec.decodeChapter(key, 'c1', {
      'titleJp': '出発',
      'paragraphs': ['一', '二'],
      'youdaoParagraphs': ['甲'],
    });

    final chapter = const NoveliaReaderAdapter()
        .buildNovel(details: details, chapters: [payload])
        .chapters
        .single;

    expect(
      chapter.translationState(TranslationSource.youdao),
      TranslationState.invalid,
    );
    expect(chapter.blocks.every((block) => block.translations.isEmpty), isTrue);
  });

  test('normalizes a TLS handshake failure as a network failure', () async {
    final gateway = HttpNoveliaGateway(client: _HandshakeHttpClient());

    await expectLater(
      gateway.listNovels(const NoveliaCatalogQuery()),
      throwsA(
        isA<NoveliaGatewayException>().having(
          (error) => error.kind,
          'kind',
          NoveliaGatewayFailureKind.network,
        ),
      ),
    );
  });
}

class _HandshakeHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    throw HandshakeException('sanitized fixture failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
