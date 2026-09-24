import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/backup/reader_backup.dart';
import 'package:jfzreader/core/database/app_database.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/features/shell/local_library_snapshot.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_download_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_illustration_loader.dart';

import 'support/illustrated_download_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteOfflineRepository repository;
  late IllustratedDownloadGateway gateway;
  late FixtureIllustrationLoader images;
  late AsyncNoveliaDownloadCoordinator downloads;
  setUp(() async {
    repository = SqliteOfflineRepository.openInMemory();
    gateway = IllustratedDownloadGateway(
      'https://images.example.test/illustration.png',
    );
    images = FixtureIllustrationLoader(await offlineIllustrationPng());
    downloads = AsyncNoveliaDownloadCoordinator(
      gateway: gateway,
      contentRepository: repository,
      offlineRepository: repository,
      canAccessRestrictedContent: () => true,
      illustrationLoader: images,
    );
    addIllustratedIntent(repository);
  });
  tearDown(() => repository.close());

  test(
    'stores actual image bytes once per URL, counts them, exports and retains them through cache eviction',
    () async {
      await downloads.synchronizeIntent('images');
      expect(images.calls, 1);
      final copy = repository.listCopies().single;
      final payload = repository.chapterPayloadById(copy.payloadId!)!;
      expect(payload.illustrations[gateway.url], images.bytes);
      expect(
        copy.originalBytes,
        utf8.encode(payload.japaneseBlocks.join()).length + images.bytes.length,
      );
      expect(repository.payloadIdsMissingIllustrations(), isEmpty);
      final blocks = const NoveliaContentCacheAdapter()
          .restoreChapter(payload)
          .blocks;
      expect(blocks.first.illustrationBytes, images.bytes);
      expect(blocks.last.illustrationBytes, images.bytes);

      // A later online read only returns text/URLs. It must retain downloaded
      // image files when updating the same payload in the shared cache.
      final textOnly = payload.withIllustrations({});
      repository.cacheChapterPayload(
        payload: textOnly,
        copy: const NoveliaContentCacheAdapter().cacheCopy(
          textOnly,
          translationSource: copy.translationSource,
          storedAt: illustrationTime,
        ),
      );
      expect(
        repository.chapterPayloadById(payload.id)!.illustrations[gateway.url],
        images.bytes,
      );

      final imported = SqliteOfflineRepository.openInMemory();
      addTearDown(imported.close);
      final encoded = repository.exportBackup(includeContent: true).encode();
      final backup = ReaderBackup.fromJson(
        jsonDecode(utf8.decode(gzip.decode(encoded))),
      );
      imported.mergeBackup(imported.previewBackup(backup));
      final importedCopy = imported.listCopies().first;
      expect(
        imported
            .chapterPayloadById(importedCopy.payloadId!)!
            .illustrations[gateway.url],
        images.bytes,
      );

      repository.evictCacheTo(maxBytes: 0);
      expect(
        repository
            .chapterPayloadById(copy.payloadId!)!
            .illustrations[gateway.url],
        images.bytes,
      );
      repository.removeIntent(
        'images',
        illustrationTime.add(const Duration(days: 1)),
      );
      expect(repository.chapterPayloadById(copy.payloadId!), isNull);
    },
  );

  test(
    'a failed image never completes the text-only task and retry downloads it',
    () async {
      images.fail = true;
      await downloads.synchronizeIntent('images');
      expect(repository.listTasks().single.state, DownloadTaskState.failed);
      expect(repository.listTasks().single.failure!.retryable, isTrue);
      expect(
        repository.listTasks().single.failure!.kind,
        DownloadFailureKind.illustration,
      );
      expect(repository.listCopies(), isEmpty);
      images.fail = false;
      repository.requeueInterruptedTasks(
        intentId: 'images',
        now: illustrationTime,
      );
      await downloads.synchronizeIntent('images');
      expect(repository.listTasks().single.state, DownloadTaskState.stored);
      expect(
        repository
            .chapterPayloadById(repository.listCopies().single.payloadId!)!
            .illustrationsComplete,
        isTrue,
      );
    },
  );

  for (final remove in [false, true]) {
    test(
      'pause/remove during image transfer cannot finish or resurrect a download (remove=$remove)',
      () async {
        final gate = Completer<void>();
        images.gate = gate.future;
        final run = downloads.synchronizeIntent('images');
        while (images.calls == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        if (remove) {
          repository.removeIntent('images', illustrationTime);
        } else {
          repository.pauseIntent('images', illustrationTime);
        }
        gate.complete();
        await run;
        expect(repository.listCopies(), isEmpty);
        expect(
          repository.listTasks().single.state,
          remove ? DownloadTaskState.removed : DownloadTaskState.paused,
        );
      },
    );
  }

  test(
    'v8 text-only downloads and v1 backups repair images without refetching text or login',
    () async {
      await downloads.synchronizeIntent('images');
      final backupMap =
          jsonDecode(
                utf8.decode(
                  gzip.decode(
                    repository.exportBackup(includeContent: true).encode(),
                  ),
                ),
              )
              as Map<String, dynamic>;
      backupMap['version'] = 1;
      for (final row
          in backupMap['tables']['cached_chapter_payloads'] as List) {
        (row as Map).remove('illustrations_json');
        row.remove('illustrations_complete');
      }
      final legacy = SqliteOfflineRepository.openInMemory();
      addTearDown(legacy.close);
      legacy.mergeBackup(
        legacy.previewBackup(ReaderBackup.fromJson(backupMap)),
      );
      expect(legacy.payloadIdsMissingIllustrations(), hasLength(1));

      // Recreate the previous schema from a real stored chapter.
      final database = NoveliaDatabase.openInMemory();
      final old = SqliteOfflineRepository.fromDatabase(database);
      old.mergeBackup(old.previewBackup(ReaderBackup.fromJson(backupMap)));
      database.execute(
        'DROP INDEX missing_illustrations_idx; ALTER TABLE cached_chapter_payloads DROP COLUMN illustrations_complete; ALTER TABLE cached_chapter_payloads DROP COLUMN illustrations_json;',
      );
      database.userVersion = 8;
      final migrated = SqliteOfflineRepository.fromDatabase(
        database,
        closeOnDispose: true,
      );
      addTearDown(migrated.close);
      final copy = migrated.listCopies().single;
      final payloadBefore = migrated.chapterPayloadById(copy.payloadId!)!;
      expect(
        migrated.payloadIdsMissingIllustrations(),
        contains(copy.payloadId),
      );
      expect(
        LocalLibrarySnapshot.load(
          migrated,
          knownNovels: const [],
        ).downloads.single.isComplete,
        isFalse,
      );
      migrated.resumeIntent(copy.intentId!, illustrationTime);
      gateway.offline = true;
      final requests = gateway.chapterRequests;
      final repair = AsyncNoveliaDownloadCoordinator(
        gateway: gateway,
        contentRepository: migrated,
        offlineRepository: migrated,
        illustrationLoader: images,
      );
      images.fail = true;
      await repair.synchronizeIntent(copy.intentId!);
      expect(
        migrated.chapterPayloadById(copy.payloadId!)!.japaneseBlocks,
        payloadBefore.japaneseBlocks,
      );
      expect(migrated.copyById(copy.id)!.storedAt, copy.storedAt);
      expect(
        migrated.payloadIdsMissingIllustrations(),
        contains(copy.payloadId),
      );
      images.fail = false;
      await repair.synchronizeIntent(copy.intentId!);
      expect(gateway.chapterRequests, requests);
      final after = migrated.chapterPayloadById(copy.payloadId!)!;
      expect(after.id, payloadBefore.id);
      expect(after.japaneseBlocks, payloadBefore.japaneseBlocks);
      expect(after.illustrations[gateway.url], images.bytes);
      expect(
        LocalLibrarySnapshot.load(
          migrated,
          knownNovels: const [],
        ).downloads.single.isComplete,
        isTrue,
      );
    },
  );

  test(
    'image loader downloads original bytes and rejects HTTP errors, HTML and oversize bodies',
    () async {
      // HttpOverrides from widget tests are intentionally not used here.
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            isNull,
          );
          expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
          if (request.uri.path == '/error') {
            request.response.statusCode = 404;
          } else if (request.uri.path == '/html') {
            request.response.write('<html>error</html>');
          } else {
            request.response.add(images.bytes);
          }
          await request.response.close();
        });
        Uri uri(String path) =>
            Uri.parse('http://127.0.0.1:${server.port}$path');
        const loader = HttpNoveliaIllustrationLoader();
        expect(await loader.load(uri('/image')), images.bytes);
        await expectLater(loader.load(uri('/error')), throwsException);
        await expectLater(loader.load(uri('/html')), throwsException);
        await expectLater(
          const HttpNoveliaIllustrationLoader(
            maximumBytes: 10,
          ).load(uri('/image')),
          throwsException,
        );
      }, FixtureHttpOverrides());
    },
  );
}
