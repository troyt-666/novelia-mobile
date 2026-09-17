import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/wenku/wenku_details_screen.dart';
import 'package:jfzreader/features/wenku/wenku_epub_document.dart';
import 'package:jfzreader/features/wenku/wenku_epub_store.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';

void main() {
  runWenkuCommentJourneys();
  testWidgets('bilingual order is locked while an EPUB download is active', (
    tester,
  ) async {
    final gateway = _PendingDownloadGateway();
    const summary = WenkuNovelSummary(
      id: 'novel-1',
      japaneseTitle: '原題',
      chineseTitle: '译名',
      coverUri: null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: WenkuDetailsScreen(
          gateway: gateway,
          summary: summary,
          store: const _EmptyEpubStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SegmentedButton<WenkuBilingualOrder>>(
            find.byType(SegmentedButton<WenkuBilingualOrder>),
          )
          .onSelectionChanged,
      isNotNull,
    );

    await tester.ensureVisible(find.text('下载并阅读'));
    await tester.pump();
    await tester.tap(find.text('下载并阅读'));
    await tester.pump();

    expect(gateway.request?.order, WenkuBilingualOrder.chineseFirst);
    expect(
      tester
          .widget<SegmentedButton<WenkuBilingualOrder>>(
            find.byType(SegmentedButton<WenkuBilingualOrder>),
          )
          .onSelectionChanged,
      isNull,
    );

    gateway.cancel();
    await tester.pumpAndSettle();
  });
}

/// Fixture-only journeys shared with native integration tests.
void runWenkuCommentJourneys({
  bool useDeviceViewport = false,
  Future<void> Function(String name)? capture,
}) {
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 220);
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> mount(
    WidgetTester tester,
    _CommentGateway gateway, {
    bool dark = false,
    double textScale = 1,
  }) async {
    if (!useDeviceViewport) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: dark ? const Color(0xFF78B99A) : const Color(0xFF397B62),
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: WenkuDetailsScreen(
          gateway: gateway,
          summary: const WenkuNovelSummary(
            id: 'fixture-wenku',
            japaneseTitle: '夜の図書館',
            chineseTitle: '夜间图书馆',
            coverUri: null,
          ),
          store: const _EmptyEpubStore(),
        ),
      ),
    );
    await tester.pump();
    await reveal(tester, find.text('读者评论'));
    await tester.pump();
  }

  testWidgets(
    'Wenku comments load, expand replies, replace pages and retry the failed page',
    (tester) async {
      final first = Completer<NoveliaPage<NoveliaComment>>();
      var secondAttempts = 0;
      final gateway = _CommentGateway((page) {
        if (page == 0) return first.future;
        secondAttempts++;
        if (secondAttempts == 1) {
          return Future.error(StateError('fixture offline'));
        }
        return Future.value(
          NoveliaPage(items: [_comment('second', '第二页评论')], pageCount: 2),
        );
      });
      await mount(tester, gateway);
      await reveal(tester, find.byKey(const ValueKey('comments-page-loading')));
      await capture?.call('wenku-comments-loading');
      expect(
        find.byKey(const ValueKey('comments-page-loading')),
        findsOneWidget,
      );
      expect(find.text('暂无评论'), findsNothing);
      first.complete(
        NoveliaPage(
          items: [
            _comment(
              'first',
              '第一卷的叙事很细腻，期待图书馆里的下一段故事。',
              replies: [
                _comment('reply', '同感，日文原文和译文对照着读很方便。'),
                _comment('hidden-reply', 'fixture hidden reply', hidden: true),
              ],
            ),
          ],
          pageCount: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('comment-reply-reply')), findsOneWidget);
      expect(find.text('该评论已隐藏'), findsOneWidget);
      expect(find.text('fixture hidden reply'), findsNothing);
      expect(find.text('共 2 页'), findsOneWidget);
      final next = find.byKey(const ValueKey('comments-next-page'));
      final previous = find.byKey(const ValueKey('comments-previous-page'));
      await reveal(tester, next);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(previous).onPressed, isNull);
      await capture?.call('wenku-comments-light');
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(find.text('无法加载这一页评论'), findsOneWidget);
      expect(find.text('暂无评论'), findsNothing);
      expect(find.byKey(const ValueKey('novel-comment-first')), findsNothing);
      final retry = find.byKey(const ValueKey('retry-comments-page'));
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await capture?.call('wenku-comments-error');
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.text('第二页评论'), findsOneWidget);
      expect(find.text('第 2 / 2 页'), findsOneWidget);
      expect(tester.widget<IconButton>(next).onPressed, isNull);
      expect(gateway.requests, [0, 1, 1]);
      await reveal(tester, previous);
      await tester.tap(previous);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('novel-comment-first')), findsOneWidget);
      expect(find.text('第二页评论'), findsNothing);
      expect(gateway.requests, [0, 1, 1, 0]);
      expect(gateway.requestedNovelIds, everyElement('fixture-wenku'));
      expect(gateway.requestedPageSizes, everyElement(10));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Wenku shows empty comments even without readable EPUBs', (
    tester,
  ) async {
    final gateway = _CommentGateway(
      (_) async => const NoveliaPage(items: [], pageCount: 0),
    );
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    await reveal(tester, find.text('暂无评论'));
    expect(find.text('暂无可读的日文 EPUB。'), findsOneWidget);
    expect(find.text('暂无评论'), findsOneWidget);
    expect(find.byKey(const ValueKey('comments-next-page')), findsNothing);
    expect(gateway.requests, [0]);
    await capture?.call('wenku-comments-empty');
  });

  testWidgets('Wenku comments remain readable in dark mode with large text', (
    tester,
  ) async {
    final gateway = _CommentGateway(
      (_) async => NoveliaPage(
        items: [
          _comment(
            'long',
            '这是用于测试换行的虚构评论。日文原文と中文译文を照らし合わせながら読むと、细节会更加清楚。',
            username: '图书馆里的长名字读者',
            replies: [_comment('long-reply', '回复也应该完整显示，在字体放大时保持自然换行。')],
          ),
        ],
        pageCount: 1,
      ),
    );
    await mount(tester, gateway, dark: true, textScale: 1.5);
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('comments-next-page')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('comment-reply-long-reply')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await capture?.call('wenku-comments-dark-large');
  });
}

NoveliaComment _comment(
  String id,
  String body, {
  String username = '虚构读者',
  bool hidden = false,
  List<NoveliaComment> replies = const [],
}) => NoveliaComment(
  id: id,
  username: username,
  content: body,
  hidden: hidden,
  createdAt: DateTime.utc(2026, 9, 18),
  replies: replies,
);

class _CommentGateway extends _PendingDownloadGateway {
  _CommentGateway(this.loadPage);
  final Future<NoveliaPage<NoveliaComment>> Function(int page) loadPage;
  final requests = <int>[];
  final requestedNovelIds = <String>[];
  final requestedPageSizes = <int>[];

  @override
  Future<NoveliaPage<NoveliaComment>> listComments(
    String novelId, {
    int page = 0,
    int pageSize = 10,
  }) {
    requestedNovelIds.add(novelId);
    requestedPageSizes.add(pageSize);
    requests.add(page);
    return loadPage(page);
  }

  @override
  Future<WenkuNovelDetails> getNovel(String novelId) async => WenkuNovelDetails(
    id: novelId,
    japaneseTitle: '夜の図書館',
    chineseTitle: '夜间图书馆',
    coverUri: null,
    authors: ['虚构作者'],
    artists: [],
    keywords: [],
    publisher: null,
    imprint: null,
    level: '轻小说',
    introduction: '一间只在夜里开门的图书馆。（界面验证用虚构数据）',
    publishedVolumes: [],
    japaneseEpubs: [],
    chineseEpubIds: [],
  );
}

class _EmptyEpubStore extends WenkuEpubStore {
  const _EmptyEpubStore();

  @override
  Future<WenkuEpubDocument?> load(WenkuEpubRequest request) async => null;
}

class _PendingDownloadGateway implements NoveliaWenkuGateway {
  WenkuEpubRequest? request;
  Completer<Uint8List>? _result;

  void cancel() {
    final result = _result;
    if (result != null && !result.isCompleted) {
      result.completeError(const WenkuEpubDownloadCancelledException());
    }
  }

  @override
  Future<NoveliaPage<WenkuNovelSummary>> listNovels(WenkuCatalogQuery query) =>
      throw UnimplementedError();

  @override
  Future<WenkuNovelDetails> getNovel(String novelId) async =>
      const WenkuNovelDetails(
        id: 'novel-1',
        japaneseTitle: '原題',
        chineseTitle: '译名',
        coverUri: null,
        authors: [],
        artists: [],
        keywords: [],
        publisher: null,
        imprint: null,
        level: '轻小说',
        introduction: '简介',
        publishedVolumes: [],
        japaneseEpubs: [
          WenkuEpubVolume(
            volumeId: 'volume-1.epub',
            totalParagraphs: 1,
            translationCounts: {WenkuTranslationProvider.sakura: 1},
          ),
        ],
        chineseEpubIds: [],
      );

  @override
  Future<NoveliaPage<NoveliaComment>> listComments(
    String novelId, {
    int page = 0,
    int pageSize = 10,
  }) async => const NoveliaPage(items: [], pageCount: 0);

  @override
  Future<Uint8List> downloadEpub(
    WenkuEpubRequest request, {
    void Function(int bytesReceived, int? totalBytes)? onReceiveProgress,
    WenkuEpubDownloadCancellationToken? cancellationToken,
  }) {
    this.request = request;
    final result = Completer<Uint8List>();
    _result = result;
    cancellationToken?.addListener(cancel);
    return result.future;
  }
}
