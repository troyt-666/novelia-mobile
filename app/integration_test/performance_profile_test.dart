import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';
import 'package:jfzreader/fixtures/reader_fixture.dart';
import 'package:jfzreader/main.dart';

import '../test/support/fixture_content_coordinator.dart';
import '../test/support/profile_download_repair.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'profile catalog and continuous bilingual reading',
    (tester) async {
      expect(
        kProfileMode,
        isTrue,
        reason: 'Frame measurements require --profile.',
      );
      final directory = await Directory.systemTemp.createTemp(
        'reader-profile-',
      );
      final repository = SqliteOfflineRepository.openFile(
        '${directory.path}/profile.sqlite',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        repository.close();
        await directory.delete(recursive: true);
      });
      const readerOnly = bool.fromEnvironment('PROFILE_READER_ONLY');
      const illustrations = bool.fromEnvironment('PROFILE_ILLUSTRATIONS');
      const backgroundRepair = bool.fromEnvironment(
        'PROFILE_BACKGROUND_REPAIR',
      );
      const repairDryRun = bool.fromEnvironment('PROFILE_REPAIR_DRY_RUN');
      final repair = backgroundRepair
          ? await ProfileDownloadRepair.seed(repository)
          : null;
      final novels = _profileNovels(
        image: illustrations ? await _profileImage() : null,
      );
      await tester.pumpWidget(
        NoveliaReaderApp(
          repository: repository,
          contentCoordinator: FixtureContentCoordinator(novels),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> scroll(int count, {bool reverse = false}) async {
        final scrollable = find.byType(Scrollable).first;
        final height = tester.getSize(scrollable).height;
        for (var i = 0; i < count; i++) {
          await tester.timedDrag(
            scrollable,
            Offset(0, height * (reverse ? .75 : -.75)),
            const Duration(milliseconds: 350),
          );
          await tester.pumpAndSettle();
        }
      }

      Future<void> measure(String name, Future<void> Function() action) async {
        debugPrint('PROFILE_START $name');
        final startChapter = repository
            .readingProgressFor(novels.first.id)
            ?.position
            .chapterId;
        final latencies = <List<int>>[];
        void recordTimings(List<ui.FrameTiming> timings) {
          for (final timing in timings) {
            latencies.add([
              timing.vsyncOverhead.inMicroseconds,
              timing.totalSpan.inMicroseconds,
            ]);
          }
        }

        if (backgroundRepair) binding.addTimingsCallback(recordTimings);
        try {
          await binding.watchPerformance(() async {
            await action();
            // Flush the engine's final batched timings before removing its listener.
            await Future<void>.delayed(const Duration(seconds: 1));
          }, reportKey: name);
        } finally {
          if (backgroundRepair) binding.removeTimingsCallback(recordTimings);
        }
        if (backgroundRepair) {
          binding.reportData!['${name}_latency_us'] = latencies;
        }
        final view = tester.view;
        binding.reportData!['${name}_display'] = {
          'refresh_hz': view.display.refreshRate,
          'physical_width': view.physicalSize.width,
          'physical_height': view.physicalSize.height,
          'device_pixel_ratio': view.devicePixelRatio,
          'start_chapter': startChapter,
          'end_chapter': repository
              .readingProgressFor(novels.first.id)
              ?.position
              .chapterId,
        };
        debugPrint('PROFILE_END $name');
      }

      if (!readerOnly) {
        await scroll(2);
        await measure('discovery_scroll', () => scroll(16));

        await tester.tap(find.byKey(const ValueKey('nav-search')));
        await tester.pumpAndSettle();
        final search = find.byKey(const ValueKey('discover-search-field'));
        await measure('search_queries', () async {
          for (final query in ['夜行', '齿轮', '庭园', '小说', 'Profile']) {
            await tester.enterText(search, query);
            await tester.testTextInput.receiveAction(TextInputAction.search);
            await tester.pumpAndSettle();
          }
        });
        FocusManager.instance.primaryFocus?.unfocus();
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        await tester.pumpAndSettle();
        await scroll(2);
        await measure('search_scroll', () => scroll(16));
      }

      // Open through the real app route so window loading and SQLite progress
      // writes are included, using deterministic content in a temporary database.
      await tester.tap(find.byKey(const ValueKey('nav-discover')));
      await tester.pumpAndSettle();
      final catalogScroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      catalogScroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(ValueKey('open-details-${novels.first.id}')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('open-details-${novels.first.id}')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('start-reading-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-stream')), findsOneWidget);
      final viewport = tester.getRect(
        find.byKey(const ValueKey('reader-stream')),
      );
      await tester.tapAt(viewport.center);
      await tester.pumpAndSettle();
      await scroll(2);
      if (repair != null) {
        await measure('reader_background_repair', () async {
          await Future.wait([if (!repairDryRun) repair.run(), scroll(18)]);
        });
        binding.reportData!['repair_image_bytes'] = repair.imageBytes;
        binding.reportData!['repair_images'] = repair.completedImages;
        expect(repair.completedImages, repairDryRun ? 0 : 24);
        for (var i = 0; i < 24; i++) {
          expect(
            repository
                .chapterPayloadById('syosetu/offline-$i:c1')!
                .illustrationsComplete,
            !repairDryRun,
          );
        }
        expect(tester.takeException(), isNull);
        return;
      }
      await measure('reader_scroll', () => scroll(18));
      await measure('reader_long_scroll', () => scroll(48));
      final position = repository.readingProgressFor(novels.first.id)!.position;
      binding.reportData!['last_chapter'] = position.chapterId;
      expect(
        int.parse(position.chapterId.split('-').last),
        inInclusiveRange(10, 199),
      );
      if (readerOnly) {
        await measure('reader_reverse_scroll', () => scroll(16, reverse: true));
      }
      binding.reportData!['illustrations'] = illustrations;
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

List<CatalogNovel> _profileNovels({Uint8List? image}) {
  final reader = ReaderNovel(
    id: 'profile-reader',
    chineseTitle: 'Profile 连续阅读',
    japaneseTitle: '連続読書',
    author: fixtureNovel.author,
    chapters: [
      for (var chapter = 1; chapter <= 200; chapter++)
        NovelChapter(
          id: 'profile-chapter-$chapter',
          index: chapter,
          chineseTitle: '第 $chapter 章：夜行列车',
          japaneseTitle: '夜行列車 $chapter',
          publishedAt: DateTime(2026, 8, 1),
          blocks: [
            for (var block = 0; block < 6; block++)
              AlignedBlock(
                id: 'profile-$chapter-$block',
                ordinal: block,
                japanese: fixtureNovel.chapters.first.blocks[block].japanese,
                translations:
                    fixtureNovel.chapters.first.blocks[block].translations,
                kind: fixtureNovel.chapters.first.blocks[block].kind,
              ),
            if (image != null && chapter % 3 == 0)
              AlignedBlock(
                id: 'profile-image-$chapter',
                ordinal: 6,
                japanese: '<图片>https://fixture.invalid/$chapter.png',
                translations: const {},
                kind: AlignedBlockKind.illustration,
                // Distinct downloaded byte buffers exercise first decoding as
                // each new illustration enters the reading window.
                illustrationBytes: Uint8List.fromList(image),
              ),
          ],
        ),
    ],
  );
  return [
    for (var index = 0; index < 500; index++)
      CatalogNovel(
        id: index == 0 ? reader.id : 'profile-novel-$index',
        chineseTitle: index == 0
            ? reader.chineseTitle
            : 'Profile 小说 $index · ${fixtureCatalogNovels[index % fixtureCatalogNovels.length].chineseTitle}',
        japaneseTitle: fixtureNovel.japaneseTitle,
        author: fixtureNovel.author,
        source: 'Kakuyomu',
        publicationState: NovelPublicationState.ongoing,
        tags: const ['幻想', '铁路', '少女', '悬疑'],
        synopsis: fixtureCatalogNovels.first.synopsis,
        wordCount: 128400,
        views: 500000 - index,
        points: 18000 - index,
        updatedAt: DateTime(2026, 8, 20).subtract(Duration(minutes: index)),
        translationCoverage: fixtureCatalogNovels.first.translationCoverage,
        readerNovel: index == 0 ? reader : null,
      ),
  ];
}

Future<Uint8List> _profileImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 1600, 2200),
    Paint()..color = const Color(0xff397b62),
  );
  for (var i = 0; i < 40; i++) {
    canvas.drawCircle(
      Offset((i * 97 % 1600).toDouble(), (i * 173 % 2200).toDouble()),
      150,
      Paint()..color = Color.fromARGB(180, 180 + i, 160 + i, 120 + i),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(1600, 2200);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}
