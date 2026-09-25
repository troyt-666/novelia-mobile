import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/features/reader/reader_screen.dart';
import 'package:jfzreader/gateway/novelia/http_novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_domain_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_download_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_illustration_loader.dart';
import 'package:jfzreader/main.dart';

/// Public article snapshots are served by tool/reader_real_content_corpus.py.
/// Neither prose nor the user's database is embedded in this test.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'profile real articles through production cache and reader',
    (tester) async {
      expect(kProfileMode, isTrue);
      const base = String.fromEnvironment(
        'PROFILE_CORPUS_URL',
        defaultValue: 'http://127.0.0.1:18764/',
      );
      const defaultReaderIndex = int.fromEnvironment('PROFILE_REAL_READER');
      const defaultBackground = bool.fromEnvironment('PROFILE_REAL_BACKGROUND');
      const defaultCacheOnly = bool.fromEnvironment('PROFILE_REAL_CACHE_ONLY');
      const defaultSelectionOff = bool.fromEnvironment(
        'PROFILE_REAL_SELECTION_OFF',
      );
      const defaultDragCount = int.fromEnvironment(
        'PROFILE_REAL_DRAGS',
        defaultValue: 24,
      );
      const defaultFlingCount = int.fromEnvironment(
        'PROFILE_REAL_FLINGS',
        defaultValue: 48,
      );
      const defaultReverseCount = int.fromEnvironment(
        'PROFILE_REAL_REVERSE',
        defaultValue: 16,
      );
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('${base}manifest'));
      final response = await request.close();
      final manifest = jsonDecode(await utf8.decodeStream(response)) as Map;
      client.close();
      final config = manifest['profile'] as Map? ?? const {};
      final readerIndex = config['reader'] as int? ?? defaultReaderIndex;
      final background = config['background'] as bool? ?? defaultBackground;
      final cacheOnly = config['cache_only'] as bool? ?? defaultCacheOnly;
      final selectionOff =
          config['selection_off'] as bool? ?? defaultSelectionOff;
      final dragCount = config['drags'] as int? ?? defaultDragCount;
      final flingCount = config['flings'] as int? ?? defaultFlingCount;
      final reverseCount = config['reverse'] as int? ?? defaultReverseCount;
      final selected = (manifest['readers'] as List)[readerIndex] as Map;
      final selectedId = selected['key'] as String;
      final chapterStats = selected['chapters'] as List;
      final directory = await Directory.systemTemp.createTemp('real-reader-');
      final repository = SqliteOfflineRepository.openFile(
        '${directory.path}/reading.sqlite',
      );
      final events = <Map<String, Object?>>[];
      var recording = false;
      void record(String name, int start, int elapsed, [String? id]) {
        if (!recording) return;
        events.add({
          'name': name,
          'start_us': start,
          'duration_us': elapsed,
          'id': id,
        });
      }

      final gateway = HttpNoveliaGateway(baseUri: Uri.parse('${base}api/'));
      final coordinator = _MeasuredContentCoordinator(
        gateway: gateway,
        contentRepository: repository,
        record: record,
        onChapterCached: ({required novelId, required chapterId}) {
          repository.evictCacheTo(
            maxBytes: 256 * 1024 * 1024,
            protectedChapters: {
              ChapterRef(novelId: novelId, chapterId: chapterId),
            },
          );
        },
      );
      final downloads = _MeasuredDownloads(
        AsyncNoveliaDownloadCoordinator(
          gateway: gateway,
          contentRepository: repository,
          offlineRepository: repository,
        ),
        record,
      );
      final downloadSwitch = ValueNotifier<NoveliaDownloadCoordinator?>(null);
      Map<String, Object?> position() {
        final value = repository.readingProgressFor(selectedId)?.position;
        return {
          'chapter': value?.chapterId,
          'block': value?.blockId,
          'offset': value?.intraBlockOffset,
        };
      }

      Future<void> measure(String name, Future<void> Function() action) async {
        final frames = <List<int>>[];
        final startPosition = position();
        var actionStart = 0;
        var actionEnd = 0;
        void timings(List<ui.FrameTiming> values) {
          for (final value in values) {
            frames.add([
              value.timestampInMicroseconds(ui.FramePhase.vsyncStart),
              value.vsyncOverhead.inMicroseconds,
              value.buildDuration.inMicroseconds,
              value.rasterDuration.inMicroseconds,
              value.totalSpan.inMicroseconds,
            ]);
          }
        }

        events.clear();
        binding.addTimingsCallback(timings);
        debugPrint('REAL_PROFILE_START $name');
        try {
          await binding.watchPerformance(() async {
            // Exclude watchPerformance's timeline setup, previous phase's
            // summary generation, and engine batches delivered after the action.
            actionStart = Timeline.now;
            recording = true;
            await action();
            actionEnd = Timeline.now;
            recording = false;
            await Future<void>.delayed(const Duration(seconds: 1));
          }, reportKey: name);
        } finally {
          binding.removeTimingsCallback(timings);
          recording = false;
        }
        final activeFrames = frames
            .where(
              (frame) => frame.first >= actionStart && frame.first <= actionEnd,
            )
            .toList();
        expect(activeFrames, isNotEmpty);
        binding.reportData!['${name}_detail'] = {
          'frames_us': activeFrames,
          'all_frames_us': frames,
          'action_start_us': actionStart,
          'action_end_us': actionEnd,
          'events': List.of(events),
          'start_position': startPosition,
          'end_position': position(),
        };
        debugPrint('REAL_PROFILE_END $name ${jsonEncode(position())}');
      }

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        gateway.close();
        downloadSwitch.dispose();
        repository.close();
        await directory.delete(recursive: true);
      });

      const domain = NoveliaDomainAdapter();
      const cache = NoveliaContentCacheAdapter();
      final now = DateTime.now().toUtc();
      CatalogNovel? readingNovel;
      var seededBooks = 0;
      var seededCatalogChapters = 0;
      for (final value in manifest['books'] as List) {
        final book = value as Map;
        // Image repair is measured separately. This run isolates old text paths.
        final id = book['key'] as String;
        if ((book['images'] as int) > 0 && id != selectedId) continue;
        final key = _key(id);
        final details = domain.mapDetails(await gateway.getNovel(key));
        repository.upsertNovelDetail(
          cache.cacheDetails(details, fetchedAt: now),
        );
        seededBooks++;
        seededCatalogChapters += details.readerNovel!.chapters.length;
        final ids = id == selectedId
            ? chapterStats.map((c) => (c as Map)['id'] as String)
            : [book['first_chapter'] as String];
        if (id == selectedId) readingNovel = details;
        for (final chapterId in ids) {
          final response = await gateway.getChapter(key, chapterId);
          final metadata = details.readerNovel!.chapters.firstWhere(
            (chapter) => chapter.id == chapterId,
          );
          var payload = cache.cacheChapter(
            response,
            metadata: metadata,
            fetchedAt: now,
          );
          if (payload.illustrationUris.isNotEmpty) {
            final images = <String, Uint8List>{};
            for (final uri in payload.illustrationUris) {
              final entry = (manifest['images'] as Map)[uri.toString()] as Map;
              images[uri
                  .toString()] = await const HttpNoveliaIllustrationLoader()
                  .load(Uri.parse('${base}images/${entry['file']}'));
            }
            payload = payload.withIllustrations(images);
          }
          expect(payload.illustrationsComplete, isTrue);
          if (cacheOnly && id == selectedId) {
            repository.cacheChapterPayload(
              payload: payload,
              copy: cache.cacheCopy(
                payload,
                translationSource: TranslationSource.sakura,
                storedAt: now,
              ),
            );
            continue;
          }
          final intentId = 'real:$id:$chapterId';
          repository.saveIntent(
            ChapterDownloadIntent(
              id: intentId,
              novelId: id,
              chapterId: chapterId,
              translationSource: TranslationSource.sakura,
              createdAt: now,
            ),
          );
          final task = repository
              .reconcileIntent(
                intentId: intentId,
                knownChapterIds: [chapterId],
                now: now,
              )
              .single;
          final fetching = task.beginFetching(now);
          repository.saveTask(fetching);
          final validating = fetching.beginValidation(now);
          repository.saveTask(validating);
          final storing = validating.beginStoring(now);
          repository.saveTask(storing);
          repository.commitDownloadedChapter(
            taskId: task.id,
            payload: payload,
            copy: cache.downloadedCopy(payload, task: storing, storedAt: now),
            now: now,
          );
          // The selected book is stable in both control and background runs.
          if (id == selectedId) repository.pauseIntent(intentId, now);
        }
      }
      expect(readingNovel, isNotNull);
      repository.saveAppSettings(
        LocalAppSettings(
          readerSettings: ReaderSettings(textSelectionEnabled: !selectionOff),
          themePreference: ThemePreference.light,
          cacheLimitBytes: 256 * 1024 * 1024,
          updatedAt: now,
        ),
      );
      final expectedSyncs = repository
          .listIntents()
          .where((i) => i.enabled)
          .length;
      await tester.pumpWidget(
        ValueListenableBuilder<NoveliaDownloadCoordinator?>(
          valueListenable: downloadSwitch,
          builder: (_, downloader, _) => NoveliaReaderApp(
            repository: repository,
            contentCoordinator: coordinator,
            downloadCoordinator: downloader,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final detailsButtons = find.byKey(ValueKey('open-details-$selectedId'));
      for (
        var attempt = 0;
        detailsButtons.evaluate().isEmpty && attempt < 20;
        attempt++
      ) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -350));
        await tester.pumpAndSettle();
      }
      expect(detailsButtons, findsAtLeastNWidgets(1));
      final detailsButton = detailsButtons.first;
      await tester.ensureVisible(detailsButton);
      await tester.pumpAndSettle();
      await measure('open_details', () async {
        await tester.tap(detailsButton);
        await tester.pumpAndSettle();
      });
      await measure('open_reader', () async {
        await tester.tap(find.byKey(const ValueKey('start-reading-button')));
        await tester.pumpAndSettle();
      });
      expect(find.byType(ReaderScreen), findsOneWidget);

      final stream = find.byKey(const ValueKey('reader-stream'));
      final scrollable = find
          .descendant(of: stream, matching: find.byType(Scrollable))
          .first;
      Future<void> scroll(
        int count, {
        bool reverse = false,
        bool fling = false,
      }) async {
        final height = tester.getSize(scrollable).height;
        for (var i = 0; i < count; i++) {
          final distance = Offset(0, height * (reverse ? .75 : -.75));
          if (fling) {
            await tester.fling(scrollable, distance, 2600);
          } else {
            await tester.timedDrag(
              scrollable,
              distance,
              const Duration(milliseconds: 350),
            );
          }
          await tester.pumpAndSettle();
        }
      }

      await scroll(2);
      // Both cases resume catalog feeds. Only background_resume also resumes
      // chapter downloads; idle_drag is not a network-isolated control.
      await measure(background ? 'background_resume' : 'idle_drag', () async {
        if (background) {
          downloadSwitch.value = downloads;
          await tester.pump();
        }
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await scroll(dragCount);
        if (background) {
          expect(downloads.completed, expectedSyncs);
          expect(downloads.failures, 0);
        }
      });
      if (!background && flingCount > 0) {
        await measure(
          'continuous_fling',
          () => scroll(flingCount, fling: true),
        );
      }
      if (!background && reverseCount > 0) {
        await measure(
          'reverse_drag',
          () => scroll(reverseCount, reverse: true),
        );
      }
      // Measure the shelf and the direct offline launch as separate actions.
      // Keep these after the original scroll phases for comparable baselines.
      Navigator.of(
        tester.element(find.byType(ReaderScreen)),
      ).popUntil((route) => route.isFirst);
      await tester.pumpAndSettle();
      await measure('shelf_entry', () async {
        await tester.tap(find.byKey(const ValueKey('nav-library')));
        await tester.pumpAndSettle();
      });
      if (!cacheOnly) {
        await tester.tap(find.byKey(const ValueKey('library-tab-downloads')));
        await tester.pumpAndSettle();
        final row = find.byKey(
          ValueKey('offline-download-$selectedId::sakura'),
        );
        expect(row, findsOneWidget);
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        final saved = repository.readingProgressFor(selectedId)!.position;
        await measure('download_open', () async {
          await tester.tap(row);
          await tester.pumpAndSettle();
        });
        final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
        expect(reader.novel.id, selectedId);
        expect(reader.initialPosition, saved);
      }
      final view = tester.view;
      binding.reportData!['real_content'] = {
        'article': selected,
        'background': background,
        'cache_only': cacheOnly,
        'selection_enabled': !selectionOff,
        'books': seededBooks,
        'catalog_chapters': seededCatalogChapters,
        'download_syncs': downloads.completed,
        'copies': repository.listCopies().length,
        'physical_width': view.physicalSize.width,
        'physical_height': view.physicalSize.height,
        'device_pixel_ratio': view.devicePixelRatio,
        'refresh_hz': view.display.refreshRate,
        'capture_time': manifest['captured_at_utc'],
      };
      expect(repository.passesIntegrityCheck, isTrue);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

NoveliaNovelKey _key(String id) {
  final parts = id.split('/');
  return NoveliaNovelKey(providerId: parts[0], novelId: parts[1]);
}

typedef _Record =
    void Function(String name, int start, int elapsed, [String? id]);

class _MeasuredContentCoordinator extends LiveFirstNoveliaContentCoordinator {
  _MeasuredContentCoordinator({
    required super.gateway,
    required super.contentRepository,
    required super.onChapterCached,
    required this.record,
  });
  final _Record record;

  NovelChapter? measure(
    String name,
    String id,
    NovelChapter? Function() action,
  ) {
    final start = Timeline.now;
    try {
      return Timeline.timeSync(name, action);
    } finally {
      record(name, start, Timeline.now - start, id);
    }
  }

  @override
  NovelChapter? cachedChapter(
    CatalogNovel novel, {
    required String chapterId,
  }) => measure(
    'chapter.cache.read',
    chapterId,
    () => super.cachedChapter(novel, chapterId: chapterId),
  );

  @override
  NovelChapter? downloadedChapter(
    CatalogNovel novel, {
    required String chapterId,
    required TranslationSource translationSource,
  }) => measure(
    'chapter.download.read',
    chapterId,
    () => super.downloadedChapter(
      novel,
      chapterId: chapterId,
      translationSource: translationSource,
    ),
  );
}

class _MeasuredDownloads implements NoveliaDownloadCoordinator {
  _MeasuredDownloads(this.delegate, this.record);
  final NoveliaDownloadCoordinator delegate;
  final _Record record;
  int completed = 0;
  int failures = 0;

  @override
  Future<NoveliaDownloadRun> synchronizeIntent(String intentId) async {
    final start = Timeline.now;
    try {
      final result = await delegate.synchronizeIntent(intentId);
      if (result.failure != null ||
          result.refreshFailureCount > 0 ||
          result.tasks.any((task) => task.state == DownloadTaskState.failed)) {
        failures++;
      }
      return result;
    } catch (_) {
      failures++;
      rethrow;
    } finally {
      completed++;
      record('download.synchronize', start, Timeline.now - start, intentId);
    }
  }
}
