import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/features/reader/reader_controls.dart';
import 'package:jfzreader/features/shell/local_library_snapshot.dart';
import 'package:jfzreader/features/shell/novelia_shell.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';
import 'package:jfzreader/gateway/novelia/novelia_download_coordinator.dart';
import 'package:jfzreader/main.dart';

import 'support/fixture_content_coordinator.dart';

class _Downloads implements NoveliaDownloadCoordinator {
  final started = <String>[];
  final waiting = Queue<(String, Completer<NoveliaDownloadRun>)>();

  @override
  Future<NoveliaDownloadRun> synchronizeIntent(String intentId) {
    started.add(intentId);
    final completer = Completer<NoveliaDownloadRun>();
    waiting.add((intentId, completer));
    return completer.future;
  }

  void finish() {
    final (intentId, completer) = waiting.removeFirst();
    completer.complete(
      NoveliaDownloadRun(
        intentId: intentId,
        availability: CatalogAvailability.available,
        usedCachedToc: false,
        knownChapterCount: 0,
        createdTaskCount: 0,
        refreshedCopyCount: 0,
        refreshFailureCount: 0,
        tasks: const [],
      ),
    );
  }
}

void main() {
  SqliteOfflineRepository repository({int intents = 1}) {
    final repo = SqliteOfflineRepository.openInMemory();
    addTearDown(repo.close);
    for (var i = 0; i < intents; i++) {
      repo.saveIntent(
        NovelDownloadIntent(
          id: 'intent-$i',
          novelId: fixtureCatalogNovels.first.id,
          translationSource: TranslationSource.sakura,
          createdAt: DateTime.utc(2026),
        ),
      );
    }
    return repo;
  }

  LocalLibrarySnapshot snapshot(SqliteOfflineRepository repo) =>
      LocalLibrarySnapshot.load(repo, knownNovels: fixtureCatalogNovels);

  NoveliaShell shell(WidgetTester tester) => tester.widget<NoveliaShell>(
    find.byType(NoveliaShell, skipOffstage: false),
  );

  Future<void> pump(
    WidgetTester tester,
    SqliteOfflineRepository repo, {
    _Downloads? downloads,
    required LibrarySnapshotLoader loader,
  }) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      NoveliaReaderApp(
        repository: repo,
        contentCoordinator: FixtureContentCoordinator(fixtureCatalogNovels),
        downloadCoordinator: downloads,
        initialLibrarySnapshot: snapshot(repo),
        librarySnapshotLoader: loader,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openCatalog(WidgetTester tester) async {
    await tester.tap(
      find
          .byKey(ValueKey('open-details-${fixtureCatalogNovels.first.id}'))
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('start-reading-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-button')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderChapterCatalogSheet), findsOneWidget);
  }

  testWidgets('foreground events share one sweep and publish once', (
    tester,
  ) async {
    final repo = repository(intents: 3);
    final downloads = _Downloads();
    var loads = 0;
    await pump(
      tester,
      repo,
      downloads: downloads,
      loader: (_) async {
        loads++;
        return snapshot(repo);
      },
    );
    final baseline = loads;
    for (var i = 0; i < 2; i++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }
    expect(downloads.started, ['intent-0']);
    expect(loads, baseline);
    for (var i = 0; i < 3; i++) {
      downloads.finish();
      await tester.pumpAndSettle();
      if (i < 2) expect(loads, baseline);
    }
    expect(downloads.started, ['intent-0', 'intent-1', 'intent-2']);
    expect(loads, baseline + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'open catalog defers all shelf reads and exit applies deletions',
    (tester) async {
      final repo = repository();
      final downloads = _Downloads();
      var loads = 0;
      await pump(
        tester,
        repo,
        downloads: downloads,
        loader: (_) async {
          loads++;
          return snapshot(repo);
        },
      );
      await openCatalog(tester);
      final before = shell(tester).protectedDownloads;
      final baseline = loads;
      repo.removeIntent('intent-0', DateTime.utc(2026, 11));
      downloads.finish();
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('chapter-catalog-list')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(loads, baseline);
      expect(shell(tester).protectedDownloads, same(before));
      Navigator.of(
        tester.element(find.byType(ReaderChapterCatalogSheet)),
      ).popUntil((route) => route.isFirst);
      await tester.pumpAndSettle();
      expect(loads, baseline + 1);
      expect(shell(tester).protectedDownloads, isEmpty);
      expect(repo.readingProgressFor(fixtureCatalogNovels.first.id), isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('return to shelf refreshes even while another check is waiting', (
    tester,
  ) async {
    final repo = repository(intents: 2);
    final downloads = _Downloads();
    var loads = 0;
    await pump(
      tester,
      repo,
      downloads: downloads,
      loader: (_) async {
        loads++;
        return snapshot(repo);
      },
    );
    await openCatalog(tester);
    downloads.finish();
    await tester.pumpAndSettle();
    final baseline = loads;
    expect(downloads.started, ['intent-0', 'intent-1']);
    Navigator.of(
      tester.element(find.byType(ReaderChapterCatalogSheet)),
    ).popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    expect(loads, baseline + 1);
    expect(
      shell(tester).continuedReads.single.novel.id,
      fixtureCatalogNovels.first.id,
    );
    expect(downloads.waiting, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an invalidated asynchronous snapshot cannot overwrite newer data',
    (tester) async {
      final repo = repository();
      final pending = <Completer<LocalLibrarySnapshot>>[];
      var hold = false;
      await pump(
        tester,
        repo,
        loader: (_) {
          if (!hold) return Future.value(snapshot(repo));
          final completer = Completer<LocalLibrarySnapshot>();
          pending.add(completer);
          return completer.future;
        },
      );
      hold = true;
      final original = shell(tester).protectedDownloads;
      final stale = snapshot(repo);
      shell(tester).onDestinationChanged!(2);
      await tester.pump();
      expect(pending, hasLength(1));
      repo.removeIntent('intent-0', DateTime.utc(2026, 11));
      shell(tester).onDestinationChanged!(0);
      pending.first.complete(stale);
      await tester.pump();
      expect(pending, hasLength(2));
      expect(shell(tester).protectedDownloads, same(original));
      pending.last.complete(snapshot(repo));
      await tester.pumpAndSettle();
      expect(shell(tester).protectedDownloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late snapshot is ignored after app disposal', (tester) async {
    final repo = repository();
    Completer<LocalLibrarySnapshot>? pending;
    await pump(
      tester,
      repo,
      loader: (_) => pending?.future ?? Future.value(snapshot(repo)),
    );
    pending = Completer();
    shell(tester).onDestinationChanged!(2);
    await tester.pump();
    final result = snapshot(repo);
    await tester.pumpWidget(const SizedBox());
    pending.complete(result);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('visible Library updates while the remaining sweep is pending', (
    tester,
  ) async {
    final repo = repository(intents: 2);
    final downloads = _Downloads();
    var loads = 0;
    await pump(
      tester,
      repo,
      downloads: downloads,
      loader: (_) async {
        loads++;
        return snapshot(repo);
      },
    );
    shell(tester).onDestinationChanged!(2);
    await tester.pumpAndSettle();
    final baseline = loads;
    downloads.finish();
    await tester.pumpAndSettle();
    expect(downloads.started, ['intent-0', 'intent-1']);
    expect(loads, baseline + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'entering the reader suppresses an already running forced refresh',
    (tester) async {
      final repo = repository();
      Completer<LocalLibrarySnapshot>? pending;
      var loads = 0;
      await pump(
        tester,
        repo,
        loader: (_) {
          loads++;
          return pending?.future ?? Future.value(snapshot(repo));
        },
      );
      pending = Completer();
      shell(tester).onDestinationChanged!(0);
      await tester.pump();
      final before = shell(tester).protectedDownloads;
      final baseline = loads;
      await openCatalog(tester);
      pending.complete(snapshot(repo));
      await tester.pumpAndSettle();
      expect(loads, baseline);
      expect(shell(tester).protectedDownloads, same(before));
      pending = null;
      Navigator.of(
        tester.element(find.byType(ReaderChapterCatalogSheet)),
      ).popUntil((route) => route.isFirst);
      await tester.pumpAndSettle();
      expect(loads, baseline + 1);
      expect(shell(tester).protectedDownloads, isNot(same(before)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed worker preserves the shelf and a later refresh retries', (
    tester,
  ) async {
    final repo = repository();
    var fail = false;
    await pump(
      tester,
      repo,
      loader: (_) async {
        if (fail) throw StateError('fixture read failed');
        return snapshot(repo);
      },
    );
    final before = shell(tester).protectedDownloads;
    fail = true;
    shell(tester).onDestinationChanged!(2);
    await tester.pumpAndSettle();
    expect(shell(tester).protectedDownloads, same(before));
    fail = false;
    repo.removeIntent('intent-0', DateTime.utc(2026, 11));
    shell(tester).onDestinationChanged!(0);
    await tester.pumpAndSettle();
    expect(shell(tester).protectedDownloads, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
