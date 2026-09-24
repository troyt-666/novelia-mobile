import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_download_coordinator.dart';
import 'package:jfzreader/main.dart';

import 'support/illustrated_download_fixture.dart';

void main() => runOfflineIllustrationReaderTest();

void runOfflineIllustrationReaderTest({
  bool useDeviceViewport = false,
  Future<void> Function(WidgetTester tester)? capture,
}) {
  testWidgets(
    'downloaded illustrations render after database reopen with image server shut down and no login',
    (tester) async {
      late SqliteOfflineRepository repository;
      late IllustratedDownloadGateway gateway;
      late Directory directory;
      var imageRequests = 0;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          directory = await Directory.systemTemp.createTemp(
            'offline-illustrations-',
          );
          final path = '${directory.path}/reader.sqlite3';
          repository = SqliteOfflineRepository.openFile(path);
          final png = await offlineIllustrationPng();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            imageRequests++;
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(png);
            await request.response.close();
          });
          gateway = IllustratedDownloadGateway(
            'http://127.0.0.1:${server.port}/illustration.png',
          );
          try {
            addIllustratedIntent(repository);
            await AsyncNoveliaDownloadCoordinator(
              gateway: gateway,
              contentRepository: repository,
              offlineRepository: repository,
              canAccessRestrictedContent: () => true,
            ).synchronizeIntent('images');
          } finally {
            await server.close(force: true);
          }
          expect(imageRequests, 1);
          expect(repository.listCopies(), hasLength(1));
          repository.saveReaderPosition(
            LocalReadingProgress(
              novelId: illustratedKey.stableId,
              position: const ReadingPosition(chapterId: 'c1', blockId: 'c1:0'),
              updatedAt: illustrationTime,
            ),
          );
          repository.close();
          repository = SqliteOfflineRepository.openFile(path);
          gateway.offline = true;
        }, FixtureHttpOverrides()),
      );
      addTearDown(() {
        repository.close();
        directory.deleteSync(recursive: true);
      });
      // Remove Flutter's process-local image cache to prove durable storage works.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.pumpWidget(
        NoveliaReaderApp(
          repository: repository,
          contentCoordinator: LiveFirstNoveliaContentCoordinator(
            gateway: gateway,
            contentRepository: repository,
          ),
        ),
      );
      final imageFinder = find.byKey(const ValueKey('block-c1:0-illustration'));
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        final raw = find.descendant(
          of: imageFinder,
          matching: find.byType(RawImage),
        );
        if (raw.evaluate().isNotEmpty &&
            tester.widget<RawImage>(raw).image != null) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(imageFinder, findsOneWidget);
      final provider = tester.widget<Image>(imageFinder).image as ResizeImage;
      expect(provider.imageProvider, isA<MemoryImage>());
      expect(
        tester
            .widget<RawImage>(
              find.descendant(of: imageFinder, matching: find.byType(RawImage)),
            )
            .image,
        isNotNull,
      );
      expect(
        find.byKey(const ValueKey('block-c1:0-illustration-failure')),
        findsNothing,
      );
      expect(imageRequests, 1);
      expect(gateway.chapterRequests, 1);
      expect(tester.takeException(), isNull);
      await capture?.call(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    variant: useDeviceViewport
        ? const DefaultTestVariant()
        : TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
