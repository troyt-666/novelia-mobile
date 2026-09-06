import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_catalog_controller.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';

import 'support/fixture_content_coordinator.dart';

void main() {
  test(
    'search and discovery share requests but own their pages independently',
    () async {
      final source = _ControlledCatalog();
      final controller = NoveliaCatalogController(
        contentCoordinator: source,
        canAccessRestrictedContent: () => false,
      );
      addTearDown(controller.dispose);
      final search = controller.refreshCatalog();
      final discovery = controller.refreshRecentlyUpdated();
      expect(source.requests, hasLength(1));
      source.complete(0, ['first']);
      await Future.wait([search, discovery]);

      final next = controller.refreshRecentlyUpdated(append: true);
      final filtered = controller.refreshCatalog(
        criteria: const CatalogCriteria(search: 'filter'),
      );
      source.complete(2, ['filtered']);
      await filtered;
      source.complete(1, ['first', 'second']);
      await next;
      expect(controller.catalog.novels.map((n) => n.id), ['syosetu/filtered']);
      expect(controller.recentlyUpdated.novels.map((n) => n.id), [
        'syosetu/first',
        'syosetu/second',
      ]);
      expect(source.requests[1].query.page, 1);
      expect(source.requests[2].query.search, 'filter');
    },
  );

  test('late searches and appends cannot overwrite a newer refresh', () async {
    final source = _ControlledCatalog();
    final controller = NoveliaCatalogController(
      contentCoordinator: source,
      canAccessRestrictedContent: () => false,
    );
    addTearDown(controller.dispose);
    final old = controller.refreshCatalog(
      criteria: const CatalogCriteria(search: 'old'),
    );
    final current = controller.refreshCatalog(
      criteria: const CatalogCriteria(search: 'new'),
    );
    source.complete(1, ['new']);
    await current;
    source.complete(0, ['old']);
    await old;
    expect(controller.catalog.novels.single.id, 'syosetu/new');

    final append = controller.refreshCatalog(append: true);
    await controller.refreshCatalog(append: true);
    expect(source.requests, hasLength(3));
    final refresh = controller.refreshCatalog();
    await controller.refreshCatalog(append: true);
    expect(source.requests, hasLength(4));
    source.complete(3, ['updated']);
    await refresh;
    source.complete(2, ['stale-page']);
    await append;
    expect(controller.catalog.novels.single.id, 'syosetu/updated');
    expect(controller.catalog.loadingMore, isFalse);
  });

  test('cached catalog rows do not replace popularity ordering', () async {
    final source = _ControlledCatalog();
    final controller = NoveliaCatalogController(
      contentCoordinator: source,
      canAccessRestrictedContent: () => false,
    );
    addTearDown(controller.dispose);
    final live = controller.refreshMostClicked();
    source.complete(0, ['popular']);
    await live;
    final cached = controller.refreshMostClicked(append: true);
    source.complete(1, ['cached'], offline: true);
    await cached;
    expect(controller.mostClicked.novels.single.id, 'syosetu/popular');
    expect(controller.mostClicked.loadMoreFailed, isTrue);
    expect(controller.mostClicked.availability, CatalogAvailability.offline);
  });
}

class _ControlledCatalog extends FixtureContentCoordinator {
  final requests =
      <
        ({
          NoveliaCatalogQuery query,
          Completer<NoveliaContentResult<NoveliaCatalogSlice>> result,
        })
      >[];

  @override
  Future<NoveliaContentResult<NoveliaCatalogSlice>> loadCatalog(
    NoveliaCatalogQuery query,
  ) {
    final result = Completer<NoveliaContentResult<NoveliaCatalogSlice>>();
    requests.add((query: query, result: result));
    return result.future;
  }

  void complete(int index, List<String> ids, {bool offline = false}) {
    final slice = NoveliaCatalogSlice(
      pageIndex: requests[index].query.page,
      totalPages: 3,
      novels: [
        for (final id in ids)
          CatalogNovel(
            id: 'syosetu/$id',
            chineseTitle: id,
            japaneseTitle: id,
            source: 'Syosetu',
            publicationState: NovelPublicationState.ongoing,
            updatedAt: null,
            tags: const [],
            translationCoverage: const [],
          ),
      ],
    );
    requests[index].result.complete(
      offline
          ? NoveliaContentResult.offline(cachedData: slice)
          : NoveliaContentResult.available(slice),
    );
  }
}
