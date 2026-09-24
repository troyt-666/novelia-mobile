import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/backup/reader_backup.dart';
import 'package:jfzreader/core/backup/wenku_backup_entry.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/features/account/remote_list_snapshots.dart';
import 'package:jfzreader/features/account/remote_novel_list_screen.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/features/shell/shell_view_models.dart';
import 'package:jfzreader/features/wenku/wenku_epub_store.dart';
import 'package:jfzreader/gateway/novelia/novelia_illustration_loader.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_account_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_coordinator.dart';
import 'package:jfzreader/main.dart';
import 'support/offline_library_fixture.dart';

import 'support/wenku_offline_fixture.dart';
import 'support/illustrated_download_fixture.dart';

const _request = WenkuEpubRequest(
  novelId: 'fixture',
  volumeId: 'vol-1',
  order: WenkuBilingualOrder.chineseFirst,
  providers: [WenkuTranslationProvider.sakura],
  filename: 'volume.epub',
);
const _novel = CatalogNovel(
  id: 'pixiv/offline',
  chineseTitle: '保存的收藏',
  japaneseTitle: '保存作品',
  source: 'Pixiv',
  publicationState: NovelPublicationState.ongoing,
  tags: ['R18'],
  translationCoverage: [],
);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=',
);

class _Images implements NoveliaIllustrationLoader {
  final calls = <String>[];
  String? failing;
  @override
  Future<Uint8List> load(Uri uri) async {
    calls.add(uri.toString());
    if (uri.toString() == failing) {
      throw const SocketException('fixture offline');
    }
    return _png;
  }
}

class _OfflineAccount implements NoveliaAccountGateway {
  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listFavoriteWebNovels({
    required String folderId,
    int page = 0,
    int pageSize = 30,
    FavoriteQuery filter = const FavoriteQuery(),
  }) async => throw const SocketException('offline');
  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listReadHistory({
    int page = 0,
    int pageSize = 30,
  }) async => throw const SocketException('offline');
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _PendingImage implements NoveliaIllustrationLoader {
  final started = Completer<void>();
  final result = Completer<Uint8List>();
  @override
  Future<Uint8List> load(Uri uri) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('offline-remaining-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'saved cloud lists survive restart, cache eviction and have no account partition',
    () {
      final path = '${root.path}/reader.sqlite';
      var repository = SqliteOfflineRepository.openFile(path);
      var snapshots = RemoteListSnapshots(repository);
      final key = RemoteListSnapshots.favoriteKey(
        'folder',
        2,
        const FavoriteQuery(),
      );
      snapshots.saveFolders([
        const LibraryFavoriteFolder(id: 'folder', title: '以前保存的收藏夹'),
      ]);
      snapshots.savePage(
        key,
        RemoteNovelPageView(novels: [_novel], pageNumber: 2, totalPages: 3),
      );
      repository.close();
      repository = SqliteOfflineRepository.openFile(path);
      addTearDown(repository.close);
      repository.evictCacheTo(maxBytes: 0);
      snapshots = RemoteListSnapshots(repository);
      expect(snapshots.folders.folders.single.title, '以前保存的收藏夹');
      expect(snapshots.page(key)!.novels.single.tags, ['R18']);
      expect(snapshots.page(key)!.pageNumber, 2);
      expect(
        snapshots.page(
          RemoteListSnapshots.favoriteKey('folder', 1, const FavoriteQuery()),
        ),
        isNull,
      );
      expect(
        snapshots.page(
          RemoteListSnapshots.favoriteKey(
            'folder',
            2,
            const FavoriteQuery(search: 'new'),
          ),
        ),
        isNull,
      );
      expect(
        repository.exportBackup().tables.containsKey('remote_list_snapshots'),
        isFalse,
      );
    },
  );

  testWidgets('cached pages remain browsable while network never returns', (
    tester,
  ) async {
    final pending = Completer<RemoteNovelPageView>();
    final pages = [
      for (var i = 1; i <= 2; i++)
        RemoteNovelPageView(novels: [_novel], pageNumber: i, totalPages: 2),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteNovelListScreen(
          title: '离线历史',
          loader: (_) => pending.future,
          cachedPage: (page, _) => pages[page - 1],
          onOpenNovel: (_) {},
          onTagSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存的收藏'), findsOneWidget);
    expect(find.text('显示本机保存的列表，正在刷新…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('remote-novel-list-next')));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    pending.completeError(const SocketException('offline'));
    await tester.pumpAndSettle();
    expect(find.text('保存的收藏'), findsOneWidget);
    expect(find.text('刷新失败，仍显示上次结果'), findsOneWidget);
  });

  testWidgets(
    'cold app opens saved favorites and history with no signed-in session',
    (tester) async {
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      final snapshots = RemoteListSnapshots(repository);
      snapshots.saveFolders([
        const LibraryFavoriteFolder(id: 'saved', title: '本机保存的收藏夹'),
      ]);
      final page = RemoteNovelPageView(
        novels: [_novel],
        pageNumber: 1,
        totalPages: 1,
      );
      snapshots.savePage(
        RemoteListSnapshots.favoriteKey('saved', 1, const FavoriteQuery()),
        page,
      );
      snapshots.savePage(RemoteListSnapshots.historyKey(1), page);
      await tester.pumpWidget(
        NoveliaReaderApp(
          repository: repository,
          contentCoordinator: LiveFirstNoveliaContentCoordinator(
            gateway: OfflineLibraryGateway(),
            contentRepository: repository,
          ),
          accountGateway: _OfflineAccount(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-library')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-tab-favorites')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本机保存的收藏夹'));
      await tester.pumpAndSettle();
      expect(find.text('保存的收藏'), findsOneWidget);
      expect(find.text('刷新失败，仍显示上次结果'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-history-button')));
      await tester.pumpAndSettle();
      expect(find.text('保存的收藏'), findsOneWidget);
      expect(find.text('阅读历史'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'legacy EPUB indexes missing images locally and removal during repair cannot resurrect it',
    () async {
      final directory = await Directory('${root.path}/wenku').create();
      final file = File('${directory.path}/legacy.epub');
      await file.writeAsBytes(
        wenkuOfflineEpub(
          extraBody: '<img src="https://fixture.invalid/image.png"/>',
        ),
      );
      await File(
        '${file.path}.json',
      ).writeAsString(jsonEncode({'title': '旧下载', 'order': 'chineseFirst'}));
      final images = _PendingImage();
      final store = WenkuEpubStore(
        rootDirectory: () async => root,
        illustrationLoader: images,
      );
      final download = (await store.listDownloads()).single;
      expect(download.missingImages, 1);
      expect(images.started.isCompleted, isFalse);
      expect(
        jsonDecode(
          await File('${file.path}.json').readAsString(),
        )['missingImages'],
        1,
      );
      await store.saveReadingPosition(
        download.fileName,
        const WenkuReadingPosition(spineIndex: 0, fraction: .4),
      );
      final repair = store.repairImages(download);
      await images.started.future;
      await store.remove(download);
      images.result.complete(_png);
      expect(await repair, isFalse);
      expect(await store.listDownloads(), isEmpty);
      expect((await store.readingPosition(download.fileName))!.fraction, .4);
    },
  );

  test(
    'EPUB embeds image, SVG image and CSS URLs; repair retains text and progress',
    () async {
      final images = _Images()..failing = 'https://fixture.invalid/two.png';
      final store = WenkuEpubStore(
        rootDirectory: () async => root,
        illustrationLoader: images,
      );
      await store.save(
        _request,
        wenkuOfflineEpub(
          extraBody: '''
      <img src="https://fixture.invalid/one.png"/>
      <svg xmlns="http://www.w3.org/2000/svg"><image href="https://fixture.invalid/one.png"/></svg>
      <p style="background-image:url(https://fixture.invalid/one.png)">背景</p>
      <img src="https://fixture.invalid/two.png"/>
      <picture><source srcset="https://fixture.invalid/one.png 1x, https://fixture.invalid/two.png 2x"/><img src="https://fixture.invalid/one.png"/></picture>
    ''',
        ),
      );
      var download = (await store.listDownloads()).single;
      expect(download.missingImages, 1);
      expect(images.calls, [
        'https://fixture.invalid/one.png',
        'https://fixture.invalid/two.png',
      ]);
      expect(download.byteCount, greaterThan(0));
      await store.saveReadingPosition(
        download.fileName,
        const WenkuReadingPosition(spineIndex: 0, fraction: .6),
      );
      images.failing = null;
      images.calls.clear();
      expect(await store.repairImages(download), isTrue);
      expect(images.calls, ['https://fixture.invalid/two.png']);
      final restarted = WenkuEpubStore(
        rootDirectory: () async => root,
        illustrationLoader: _Images()..failing = 'unused',
      );
      download = (await restarted.listDownloads()).single;
      expect(download.missingImages, 0);
      final html = (await restarted.openDownload(
        download,
      )).htmlForSpine(0, dark: false, fontSize: 18, japaneseFirst: false);
      expect(html, contains('data:image/png;base64,'));
      expect(html, isNot(contains('https://fixture.invalid')));
      expect(html, contains('即使没有网络'));
      expect(
        (await restarted.readingPosition(download.fileName))!.fraction,
        .6,
      );
      await restarted.remove(download);
      expect(await restarted.listDownloads(), isEmpty);
      expect(
        (await restarted.readingPosition(download.fileName))!.fraction,
        .6,
      );
      expect(
        (await restarted.backupEntries(
          includeContent: false,
        )).single.spineIndex,
        0,
      );
    },
  );

  test(
    'simultaneous saves through separate store instances commit matching EPUB and metadata',
    () async {
      final first = WenkuEpubStore(rootDirectory: () async => root);
      final second = WenkuEpubStore(rootDirectory: () async => root);
      await Future.wait([
        first.save(_request, wenkuOfflineEpub(title: '第一份正文'), title: '第一份正文'),
        second.save(_request, wenkuOfflineEpub(title: '第二份正文'), title: '第二份正文'),
      ]);
      final download = (await first.listDownloads()).single;
      expect((await first.openDownload(download)).title, download.title);
      expect(['第一份正文', '第二份正文'], contains(download.title));
    },
  );

  test(
    'SVG illustrations validate as images and do not silently retain external dependencies',
    () => HttpOverrides.runWithHttpOverrides(() async {
      var body =
          '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write(body);
        await request.response.close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/picture.svg');
      const loader = HttpNoveliaIllustrationLoader(allowSvg: true);
      expect(utf8.decode(await loader.load(uri)), contains('<svg'));
      body =
          '<svg xmlns="http://www.w3.org/2000/svg"><style>rect{fill:url(missing.png)}</style></svg>';
      await expectLater(
        loader.load(uri),
        throwsA(isA<NoveliaGatewayException>()),
      );
      body = '<html><body>Error</body></html>';
      await expectLater(
        loader.load(uri),
        throwsA(isA<NoveliaGatewayException>()),
      );
    }, FixtureHttpOverrides()),
  );

  test(
    'backup includes EPUB and progress, imports without network, and is idempotent',
    () async {
      final source = WenkuEpubStore(
        rootDirectory: () async => Directory('${root.path}/source'),
      );
      await source.save(_request, wenkuOfflineEpub());
      final name = source.fileNameForRequest(_request);
      await source.saveReadingPosition(
        name,
        const WenkuReadingPosition(spineIndex: 0, fraction: .65),
      );
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      final backup = repository
          .exportBackup(includeContent: true)
          .withWenku(await source.backupEntries(includeContent: true));
      final decoded = ReaderBackup.fromJson(
        jsonDecode(utf8.decode(gzip.decode(backup.encode()))),
      );
      expect(decoded.wenku.single.bytes, isNotEmpty);
      final target = WenkuEpubStore(
        rootDirectory: () async => Directory('${root.path}/target'),
      );
      await target.mergeBackupEntries(
        decoded.wenku,
        () => repository.mergeBackup(repository.previewBackup(decoded)),
      );
      expect((await target.listDownloads()).single.fileName, name);
      expect((await target.readingPosition(name))!.fraction, .65);
      await target.saveReadingPosition(
        name,
        const WenkuReadingPosition(spineIndex: 0, fraction: .9),
      );
      await target.mergeBackupEntries(
        decoded.wenku,
        () => repository.mergeBackup(repository.previewBackup(decoded)),
      );
      expect(await target.listDownloads(), hasLength(1));
      expect((await target.readingPosition(name))!.fraction, .9);
      final records = await source.backupEntries(includeContent: false);
      expect(records.single.bytes, isNull);
      expect(records.single.fraction, .65);
    },
  );

  test(
    'failed database merge rolls back added EPUBs and progress; bad archives never partially import',
    () async {
      final store = WenkuEpubStore(rootDirectory: () async => root);
      final entry = WenkuBackupEntry(
        fileName: 'fixture.epub',
        title: 'fixture',
        spineIndex: 0,
        fraction: .7,
        bytes: wenkuOfflineEpub(),
      );
      await expectLater(
        store.mergeBackupEntries([
          entry,
        ], () => throw StateError('fixture database failure')),
        throwsStateError,
      );
      expect(await store.listDownloads(), isEmpty);
      expect(await store.readingPosition(entry.fileName), isNull);
      await expectLater(
        store.mergeBackupEntries([
          entry,
          WenkuBackupEntry(
            fileName: 'bad.epub',
            title: 'bad',
            bytes: Uint8List(10),
          ),
        ], () {}),
        throwsException,
      );
      expect(await store.listDownloads(), isEmpty);
      expect(await store.readingPosition(entry.fileName), isNull);
      expect(
        () => WenkuBackupEntry(fileName: '../escape.epub', title: 'bad'),
        throwsFormatException,
      );
    },
  );
}
