import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jfzreader/core/backup/reader_backup.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/features/account/remote_novel_list_screen.dart';
import 'package:jfzreader/features/backup/backup_screen.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/features/shell/download_management_screen.dart';
import 'package:jfzreader/features/shell/library_screen.dart';
import 'package:jfzreader/features/shell/settings_screen.dart';
import 'package:jfzreader/features/wenku/wenku_epub_store.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../test/support/backup_screen_fixture.dart';
import '../test/support/wenku_offline_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'restored EPUB images load with server closed, through unified offline UI',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'offline-complete-native-',
      );
      addTearDown(() => root.delete(recursive: true));
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 160, 120),
        Paint()..color = const Color(0xff397b62),
      );
      canvas.drawCircle(
        const Offset(80, 60),
        30,
        Paint()..color = const Color(0xfff8ecd0),
      );
      final picture = recorder.endRecording();
      final fixtureImage = await picture.toImage(160, 120);
      final imageBytes = (await fixtureImage.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      fixtureImage.dispose();
      picture.dispose();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(imageBytes);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final source = WenkuEpubStore(
        rootDirectory: () async => Directory('${root.path}/source'),
      );
      const request = WenkuEpubRequest(
        novelId: 'fixture',
        volumeId: '第一卷',
        order: WenkuBilingualOrder.chineseFirst,
        providers: [WenkuTranslationProvider.sakura],
        filename: 'fixture.epub',
      );
      await source.save(
        request,
        wenkuOfflineEpub(
          extraBody:
              '<img alt="离线插图" src="http://127.0.0.1:${server.port}/image.png"/>',
        ),
        title: '已经保存的文库与插图',
      );
      final name = source.fileNameForRequest(request);
      await source.saveReadingPosition(
        name,
        const WenkuReadingPosition(spineIndex: 0, fraction: 0),
      );
      expect((await source.listDownloads()).single.missingImages, 0);
      expect(requests, 1);
      await server.close(force: true);

      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      final backup = repository
          .exportBackup(includeContent: true)
          .withWenku(await source.backupEntries(includeContent: true));
      final file = File('${root.path}/fixture.jfzbackup');
      await file.writeAsBytes(backup.encode());
      final files = FixtureBackupFiles()
        ..incoming = await ReaderBackup.readFile(file.path);
      final target = WenkuEpubStore(
        rootDirectory: () async => Directory('${root.path}/target'),
      );
      final screenshots = <String, String>{};
      binding.reportData = {'screenshots': screenshots};
      final captureKey = GlobalKey();
      Future<void> show(Widget screen) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: const [Locale('zh', 'CN')],
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xff397b62),
                ),
              ),
              home: screen,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          screenshots[name] = base64Encode(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      Future<void> tap(String key) async {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
      }

      await show(
        BackupScreen(
          repository: repository,
          wenkuStore: target,
          files: files,
          onImported: () {},
        ),
      );
      await tap('backup-import');
      expect(find.textContaining('1 卷 EPUB'), findsOneWidget);
      await capture('offline-wenku-backup-preview');
      await tap('backup-merge');
      expect((await target.listDownloads()).single.fileName, name);
      expect(await target.readingPosition(name), isNotNull);

      await show(
        DownloadManagementScreen(
          downloads: const [],
          wenkuStore: target,
          onAction: (_, _) async => null,
          onOpenNovel: (_) {},
        ),
      );
      for (
        var i = 0;
        i < 50 && find.text('已经保存的文库与插图').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('已经保存的文库与插图'), findsOneWidget);
      expect(find.text('还没有离线下载'), findsNothing);
      await capture('offline-unified-downloads');
      await tester.tap(find.text('已经保存的文库与插图'));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<WebViewWidget>(find.byType(WebViewWidget))
          .platform
          .params
          .controller;
      var width = 0;
      for (var i = 0; i < 100; i++) {
        width =
            num.tryParse(
              (await controller.runJavaScriptReturningResult(
                'document.querySelector("img")?.naturalWidth || 0',
              )).toString(),
            )?.toInt() ??
            0;
        if (width > 0) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      debugPrint(
        'Offline restored image: ${await controller.runJavaScriptReturningResult('JSON.stringify({width: document.querySelector("img")?.naturalWidth, source: document.querySelector("img")?.src?.slice(0, 32), state: document.readyState})')}',
      );
      expect(width, 160);
      expect(
        (await controller.runJavaScriptReturningResult(
          'document.querySelector("img").src',
        )).toString(),
        contains('data:image/png;base64,'),
      );
      expect(requests, 1);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      final downloads = await target.listDownloads();
      await show(
        Scaffold(
          body: LibraryScreen(
            onOpenNovel: (_) {},
            wenkuStore: target,
            wenkuDownloads: downloads,
          ),
        ),
      );
      await tap('library-tab-downloads');
      expect(find.text('已经保存的文库与插图'), findsOneWidget);
      expect(find.text('1 项下载'), findsOneWidget);
      await capture('offline-wenku-library');
      await show(
        Scaffold(
          body: SettingsScreen(
            themeMode: ThemeMode.light,
            onThemeModeChanged: (_) {},
            onClearSearchHistory: () {},
            wenkuCount: 1,
            wenkuBytes: downloads.single.byteCount,
          ),
        ),
      );
      expect(find.textContaining('文库 1 卷'), findsOneWidget);
      await capture('offline-wenku-storage');

      final pending = Completer<RemoteNovelPageView>();
      await show(
        RemoteNovelListScreen(
          title: '已保存的阅读历史',
          loader: (_) => pending.future,
          cachedPage: (page, _) => RemoteNovelPageView(
            pageNumber: page,
            totalPages: 1,
            novels: const [
              CatalogNovel(
                id: 'fixture',
                chineseTitle: '断网仍能看到的记录',
                japaneseTitle: '保存済み',
                source: 'Pixiv',
                publicationState: NovelPublicationState.ongoing,
                tags: ['R18'],
                translationCoverage: [],
              ),
            ],
          ),
          onOpenNovel: (_) {},
          onTagSelected: (_) {},
        ),
      );
      expect(find.text('断网仍能看到的记录'), findsOneWidget);
      await capture('offline-cached-history');
      await tester.pumpWidget(const SizedBox());
      pending.completeError(const SocketException('offline fixture'));
      await tester.pumpAndSettle();
    },
  );
}
