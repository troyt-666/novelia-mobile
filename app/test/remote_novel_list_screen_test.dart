import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/account/remote_novel_list_screen.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';

void main() {
  testWidgets('loads authoritative pages and opens a selected novel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requestedPages = <int>[];
    CatalogNovel? opened;

    await tester.pumpWidget(
      MaterialApp(
        home: RemoteNovelListScreen(
          title: '阅读历史',
          loader: (page) async {
            requestedPages.add(page);
            return RemoteNovelPageView(
              novels: [fixtureCatalogNovels[page - 1]],
              pageNumber: page,
              totalPages: 2,
            );
          },
          onOpenNovel: (novel) => opened = novel,
          onTagSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(fixtureCatalogNovels.first.chineseTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('remote-novel-list-next')));
    await tester.pumpAndSettle();
    expect(find.text(fixtureCatalogNovels[1].chineseTitle), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('open-details-${fixtureCatalogNovels[1].id}')),
    );

    expect(requestedPages, [1, 2, 1]);
    expect(opened, same(fixtureCatalogNovels[1]));
  });

  testWidgets('refresh and app resume read external additions and removals', (
    tester,
  ) async {
    var novels = <CatalogNovel>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteNovelListScreen(
          title: '收藏夹',
          loader: (page) async => RemoteNovelPageView(
            novels: novels,
            pageNumber: page,
            totalPages: 1,
          ),
          onOpenNovel: (_) {},
          onTagSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('这里还没有小说'), findsOneWidget);
    novels = [fixtureCatalogNovels.first];
    await tester.tap(find.byKey(const ValueKey('refresh-remote-novel-list')));
    await tester.pumpAndSettle();
    expect(find.text(novels.first.chineseTitle), findsOneWidget);
    novels = [];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('这里还没有小说'), findsOneWidget);
  });

  testWidgets('reports a failed page and retries the same page', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteNovelListScreen(
          title: '收藏夹',
          loader: (page) async {
            attempts += 1;
            if (attempts == 1) throw StateError('offline');
            return RemoteNovelPageView(
              novels: const [],
              pageNumber: page,
              totalPages: 0,
            );
          },
          onOpenNovel: (_) {},
          onTagSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-novel-list-error')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('retry-remote-novel-list')));
    await tester.pumpAndSettle();

    expect(find.text('这里还没有小说'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('confirms Favorite removal and reloads the current page', (
    tester,
  ) async {
    var loads = 0;
    CatalogNovel? removed;
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteNovelListScreen(
          title: '默认收藏夹',
          loader: (page) async {
            loads += 1;
            return RemoteNovelPageView(
              novels: loads == 1 ? [fixtureCatalogNovels.first] : const [],
              pageNumber: page,
              totalPages: loads == 1 ? 1 : 0,
            );
          },
          onOpenNovel: (_) {},
          onTagSelected: (_) {},
          onRemoveNovel: (novel) async => removed = novel,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey('remove-favorite-${fixtureCatalogNovels.first.id}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('移出收藏夹？'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-remove-favorite')));
    await tester.pumpAndSettle();

    expect(removed, same(fixtureCatalogNovels.first));
    expect(loads, 2);
    expect(find.text('这里还没有小说'), findsOneWidget);
    expect(find.text('已移出收藏夹'), findsOneWidget);
  });

  testWidgets('failed Favorite removal leaves the row available', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteNovelListScreen(
          title: '默认收藏夹',
          loader: (page) async {
            loads += 1;
            return RemoteNovelPageView(
              novels: [fixtureCatalogNovels.first],
              pageNumber: page,
              totalPages: 1,
            );
          },
          onOpenNovel: (_) {},
          onTagSelected: (_) {},
          onRemoveNovel: (_) => throw StateError('offline'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey('remove-favorite-${fixtureCatalogNovels.first.id}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-remove-favorite')));
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(
      find.byKey(ValueKey('remove-favorite-${fixtureCatalogNovels.first.id}')),
      findsOneWidget,
    );
    expect(find.text('移除失败，请检查网络后重试'), findsOneWidget);
  });
}
