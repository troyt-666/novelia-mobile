import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/account/favorite_query.dart';
import 'package:jfzreader/features/account/remote_novel_list_screen.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';

void main() => runFavoriteFilterJourneys();

void runFavoriteFilterJourneys({
  bool useDeviceViewport = false,
  Future<void> Function(String name)? capture,
}) {
  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    if (finder.evaluate().isEmpty) {
      final options = find.byKey(const ValueKey('favorite-filter-options'));
      await tester.scrollUntilVisible(
        finder,
        300,
        scrollable: find.descendant(
          of: options.evaluate().isNotEmpty
              ? options
              : find.byKey(const ValueKey('remote-novel-page-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String value) async {
    await tester.enterText(
      find.byKey(const ValueKey('favorite-search')),
      value,
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  Future<void> pump(
    WidgetTester tester,
    FavoriteNovelPageLoader loader, {
    double scale = 1,
    bool dark = false,
    FutureOr<void> Function()? onOpen,
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
            seedColor: const Color(0xff397b62),
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RemoteNovelListScreen.favorites(
          title: '我的收藏',
          loader: loader,
          onOpenNovel: (_) => onOpen?.call(),
          onTagSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  RemoteNovelPageView result(int page, {bool empty = false, int total = 2}) =>
      RemoteNovelPageView(
        novels: empty ? [] : [fixtureCatalogNovels.first],
        pageNumber: page,
        totalPages: empty ? 0 : total,
      );

  testWidgets(
    'favorite search and every filter use the same server query across pages',
    (tester) async {
      final requests = <(int, FavoriteQuery)>[];
      var failNext = false;
      await pump(tester, (page, filter) async {
        requests.add((page, filter));
        if (failNext) {
          failNext = false;
          throw StateError('fixture offline');
        }
        return result(page, empty: filter.providers.isEmpty);
      });
      expect(requests.single.$2, const FavoriteQuery());
      if (capture != null) await capture('favorites-default');
      await tap(tester, 'remote-novel-list-next');
      expect(requests.last.$1, 2);
      await search(tester, ' 図書館 作者 ');
      expect(requests.last, (1, const FavoriteQuery(search: '図書館 作者')));
      await tap(tester, 'favorite-filters');
      final beforeEdit = requests.length;
      await tap(tester, 'favorite-providers-invert');
      await tap(tester, 'favorite-provider-pixiv');
      await tap(tester, 'favorite-provider-hameln');
      await tap(tester, 'favorite-publication-completed');
      await tap(tester, 'favorite-rating-r18');
      await tap(tester, 'favorite-translation-sakura');
      expect(requests.length, beforeEdit);
      if (capture != null) await capture('favorites-filter-options');
      await tap(tester, 'favorite-filter-apply');
      final combined = const FavoriteQuery(
        search: '図書館 作者',
        providers: [FavoriteProvider.hameln, FavoriteProvider.pixiv],
        publication: FavoritePublication.completed,
        rating: FavoriteRating.r18,
        translation: FavoriteTranslation.sakura,
      );
      expect(requests.last, (1, combined));
      expect(find.text('筛选 · 4'), findsOneWidget);
      await tap(tester, 'favorite-sort');
      await tap(tester, 'favorite-sort-created');
      final sorted = combined.copyWith(sort: FavoriteSort.created);
      expect(requests.last, (1, sorted));
      if (capture != null) await capture('favorites-filtered');
      failNext = true;
      await tap(tester, 'remote-novel-list-next');
      expect(
        find.byKey(const ValueKey('remote-novel-list-error')),
        findsOneWidget,
      );
      expect(requests.last, (2, sorted));
      if (capture != null) await capture('favorites-error');
      await tap(tester, 'retry-remote-novel-list');
      expect(requests.last, (2, sorted));
      expect(find.text('2 / 2'), findsOneWidget);
      await tap(tester, 'favorite-filters');
      final beforeCancel = requests.length;
      await tap(tester, 'favorite-filter-reset');
      await tap(tester, 'favorite-filter-cancel');
      expect(requests.length, beforeCancel);
      expect(find.text('筛选 · 4'), findsOneWidget);
      await tap(tester, 'favorite-search-clear');
      expect(requests.last, (1, sorted.copyWith(search: '')));
      await tap(tester, 'favorite-filters');
      await tap(tester, 'favorite-providers-all');
      await tap(tester, 'favorite-providers-invert');
      await tap(tester, 'favorite-filter-apply');
      expect(requests.last.$2.providers, isEmpty);
      expect(find.textContaining('没有符合条件的收藏'), findsOneWidget);
      if (capture != null) await capture('favorites-empty');
      await tap(tester, 'favorite-reset');
      expect(requests.last, (1, const FavoriteQuery()));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('favorite-search')))
            .controller!
            .text,
        '',
      );
      expect(tester.takeException(), isNull);
    },
  );

  // Artificially pending futures are exercised with the deterministic widget
  // clock. Native runs cover the controls, IME, pagination and visual states.
  if (!useDeviceViewport) {
    testWidgets('late favorite results cannot replace a newer query', (
      tester,
    ) async {
      final oldResult = Completer<RemoteNovelPageView>();
      await pump(
        tester,
        (page, filter) async => filter.search == 'old'
            ? oldResult.future
            : result(page, empty: filter.search == 'new'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('favorite-search')),
        'old',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await search(tester, 'new');
      expect(find.textContaining('没有符合条件的收藏'), findsOneWidget);
      oldResult.complete(result(1));
      await tester.pumpAndSettle();
      expect(find.textContaining('没有符合条件的收藏'), findsOneWidget);
      expect(find.text(fixtureCatalogNovels.first.chineseTitle), findsNothing);
    });

    testWidgets(
      'returning from a favorite retains query page and scroll while refreshing',
      (tester) async {
        final requests = <(int, FavoriteQuery)>[];
        final returned = Completer<void>();
        await pump(tester, (page, filter) async {
          requests.add((page, filter));
          return RemoteNovelPageView(
            novels: fixtureCatalogNovels.take(3).toList(),
            pageNumber: page,
            totalPages: 2,
          );
        }, onOpen: () => returned.future);
        await search(tester, '列车');
        await tap(tester, 'remote-novel-list-next');
        final list = find.byKey(const ValueKey('remote-novel-page-scroll'));
        final controller = tester.widget<ListView>(list).controller!;
        controller.jumpTo(200);
        await tester.pumpAndSettle();
        final book = find.byKey(
          ValueKey('open-details-${fixtureCatalogNovels[1].id}'),
        );
        await tester.ensureVisible(book);
        await tester.pumpAndSettle();
        final offset = controller.offset;
        expect(offset, greaterThan(0));
        await tester.tap(book);
        await tester.pump();
        returned.complete();
        await tester.pumpAndSettle();
        expect(requests.last, (2, const FavoriteQuery(search: '列车')));
        expect(controller.offset, closeTo(offset, 1));
        expect(find.text('2 / 2'), findsOneWidget);
      },
    );
  }

  for (final dark in [false, true]) {
    testWidgets('favorite filters fit large text (dark=$dark)', (tester) async {
      await pump(
        tester,
        (page, filter) async => result(page, empty: true),
        scale: 2,
        dark: dark,
      );
      await tap(tester, 'favorite-filters');
      if (capture != null) {
        await capture('favorites-large-${dark ? 'dark' : 'light'}');
      }
      await tap(tester, 'favorite-rating-r18');
      await tap(tester, 'favorite-translation-gpt');
      await tap(tester, 'favorite-filter-apply');
      if (capture != null) {
        await capture('favorites-large-result-${dark ? 'dark' : 'light'}');
      }
      expect(find.text('筛选 · 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
