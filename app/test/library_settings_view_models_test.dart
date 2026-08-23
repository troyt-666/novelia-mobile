import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/core/platform/app_update.dart';
import 'package:jfzreader/core/platform/app_update_installer.dart';
import 'package:jfzreader/core/platform/app_version.dart';
import 'package:jfzreader/features/shell/library_screen.dart';
import 'package:jfzreader/features/shell/settings_screen.dart';
import 'package:jfzreader/features/shell/shell_view_models.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(480, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
    await tester.pumpAndSettle();
  }

  group('LibraryScreen', () {
    testWidgets('legacy novels do not fabricate local library records', (
      tester,
    ) async {
      await pumpScreen(tester, LibraryScreen(onOpenNovel: (_) {}));

      expect(find.text('还没有阅读记录'), findsOneWidget);
      expect(find.text('远程收藏夹暂不可用'), findsOneWidget);
      expect(find.text('还没有离线小说'), findsOneWidget);
      expect(find.text('还没有书签'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('favorite-folders-grid')),
        findsOneWidget,
      );
      expect(find.text(fixtureCatalogNovels.first.chineseTitle), findsNothing);
      expect(find.textContaining('42%'), findsNothing);
      expect(find.textContaining('6.8 MB'), findsNothing);
    });

    testWidgets('renders supplied progress downloads favorites and bookmarks', (
      tester,
    ) async {
      final openedNovelIds = <String>[];
      final openedFolderIds = <String>[];
      final firstNovel = fixtureCatalogNovels.first;
      final secondNovel = fixtureCatalogNovels[1];
      const continuedPosition = ReadingPosition(
        chapterId: 'chapter-3',
        blockId: 'block-7',
        intraBlockOffset: 13,
      );
      const bookmarkPosition = ReadingPosition(
        chapterId: 'chapter-2',
        blockId: 'block-4',
      );

      await pumpScreen(
        tester,
        LibraryScreen(
          onOpenNovel: (novel) => openedNovelIds.add(novel.id),
          continuedReads: [
            LibraryContinuedRead(
              novel: firstNovel,
              position: continuedPosition,
              progress: 0.375,
              chapterLabel: '第三章',
            ),
          ],
          protectedDownloads: [
            LibraryProtectedDownload(
              novel: firstNovel,
              translationSource: TranslationSource.sakura,
              chapters: [
                LibraryDownloadChapter(
                  chapterId: 'chapter-1',
                  byteCount: 1024,
                  translationAvailable: true,
                  taskState: DownloadTaskState.stored,
                ),
                LibraryDownloadChapter(
                  chapterId: 'chapter-2',
                  byteCount: 2048,
                  translationAvailable: false,
                  taskState: DownloadTaskState.stored,
                ),
              ],
            ),
          ],
          bookmarks: [
            LibraryBookmarkItem(
              id: 'bookmark-real',
              novel: secondNovel,
              position: bookmarkPosition,
              chapterLabel: '第二章',
            ),
          ],
          remoteFavorites: RemoteFavoritesViewModel.available(const [
            LibraryFavoriteFolder(id: 'later', title: '稍后阅读', novelCount: 12),
          ]),
          onFavoriteFolderRequested: (folder) => openedFolderIds.add(folder.id),
        ),
      );

      expect(find.text('第三章 · 38%'), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(progress.value, 0.375);
      expect(find.text('2 章 · Sakura · 3.00 KB · 1 章待翻译'), findsOneWidget);
      expect(find.text('稍后阅读'), findsOneWidget);
      expect(find.text('12 部小说'), findsOneWidget);
      expect(find.text('第二章'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('continued-read-${firstNovel.id}')));
      await tester.tap(
        find.byKey(ValueKey('offline-download-${firstNovel.id}')),
      );
      await tester.tap(find.byKey(const ValueKey('bookmark-bookmark-real')));
      await tester.tap(find.byKey(const ValueKey('favorite-folder-later')));
      expect(openedNovelIds, [firstNovel.id, firstNovel.id, secondNovel.id]);
      expect(openedFolderIds, ['later']);
    });

    testWidgets('remote empty is distinct from remote unavailable', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        LibraryScreen(
          onOpenNovel: (_) {},
          remoteFavorites: const RemoteFavoritesViewModel.empty(),
        ),
      );

      expect(find.text('收藏夹为空'), findsOneWidget);
      expect(find.text('远程收藏夹暂不可用'), findsNothing);
    });

    testWidgets('continued reading separates resume from novel details', (
      tester,
    ) async {
      final novel = fixtureCatalogNovels.first;
      const position = ReadingPosition(chapterId: 'chapter-2', blockId: 'c2-0');
      final resumedPositions = <ReadingPosition>[];
      final detailNovelIds = <String>[];

      await pumpScreen(
        tester,
        LibraryScreen(
          onOpenNovel: (value) => detailNovelIds.add(value.id),
          onOpenPosition: (_, value) => resumedPositions.add(value),
          continuedReads: [
            LibraryContinuedRead(
              novel: novel,
              position: position,
              progress: 0.4,
            ),
          ],
        ),
      );

      await tester.tap(find.byKey(ValueKey('continued-read-${novel.id}')));
      expect(resumedPositions, [position]);
      expect(detailNovelIds, isEmpty);

      await tester.tap(
        find.byKey(ValueKey('continued-read-details-${novel.id}')),
      );
      expect(resumedPositions, [position]);
      expect(detailNovelIds, [novel.id]);
    });
  });

  group('SettingsScreen', () {
    testWidgets('truthful defaults report zero storage and unknown limit', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        SettingsScreen(
          appVersion: const AppVersion(name: '1.2.3', buildNumber: '45'),
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          onClearSearchHistory: () {},
        ),
      );

      expect(find.text('0 B · 0 部小说 · 0 章'), findsOneWidget);
      expect(find.text('0 B · 0 章 · 上限未设置'), findsOneWidget);
      expect(find.text('1.2.3+45 · 手动安装版'), findsOneWidget);
      expect(find.textContaining('6.8 MB'), findsNothing);
      expect(find.textContaining('2.3 MB'), findsNothing);
    });

    testWidgets(
      'renders repository storage summary and configured cache limit',
      (tester) async {
        await pumpScreen(
          tester,
          SettingsScreen(
            themeMode: ThemeMode.system,
            onThemeModeChanged: (_) {},
            onClearSearchHistory: () {},
            storageSummary: const OfflineStorageSummary(
              cacheBytes: 2 * 1024 * 1024,
              offlineDownloadBytes: 7 * 1024 * 1024,
              cacheChapterCount: 3,
              offlineDownloadChapterCount: 5,
              perNovel: [
                NovelStorageSummary(
                  novelId: 'novel-a',
                  cacheBytes: 2 * 1024 * 1024,
                  offlineDownloadBytes: 4 * 1024 * 1024,
                  cacheChapterCount: 3,
                  offlineDownloadChapterCount: 3,
                  translationSources: {TranslationSource.sakura},
                ),
                NovelStorageSummary(
                  novelId: 'novel-b',
                  cacheBytes: 0,
                  offlineDownloadBytes: 3 * 1024 * 1024,
                  cacheChapterCount: 0,
                  offlineDownloadChapterCount: 2,
                  translationSources: {TranslationSource.gpt},
                ),
              ],
            ),
            cacheLimitBytes: 256 * 1024 * 1024,
          ),
        );

        expect(find.text('7.00 MB · 2 部小说 · 5 章'), findsOneWidget);
        expect(find.text('2.00 MB · 3 章 · 上限 256 MB'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings-offline-storage')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-cache-storage')),
          findsOneWidget,
        );
      },
    );

    testWidgets('storage and privacy rows perform their advertised actions', (
      tester,
    ) async {
      var openedDownloads = 0;
      var clearedCache = 0;
      final cacheLimits = <int>[];
      await pumpScreen(
        tester,
        SettingsScreen(
          appVersion: const AppVersion(name: '1.2.3', buildNumber: '45'),
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          onClearSearchHistory: () {},
          onManageOfflineDownloads: () => openedDownloads += 1,
          onCacheLimitChanged: cacheLimits.add,
          onClearReadingCache: () async {
            clearedCache += 1;
            return 3;
          },
          storageSummary: const OfflineStorageSummary(
            cacheBytes: 2048,
            offlineDownloadBytes: 4096,
            cacheChapterCount: 3,
            offlineDownloadChapterCount: 2,
            perNovel: [],
          ),
          cacheLimitBytes: 256 * 1024 * 1024,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('settings-offline-storage')));
      expect(openedDownloads, 1);

      await tester.tap(find.byKey(const ValueKey('settings-cache-storage')));
      await tester.pumpAndSettle();
      expect(find.textContaining('不会删除离线下载'), findsOneWidget);
      expect(find.text('当前 2.00 KB · 3 章'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cache-limit-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('512 MB').last);
      await tester.pumpAndSettle();
      expect(cacheLimits, [512 * 1024 * 1024]);

      await tester.tap(
        find.byKey(const ValueKey('clear-reading-cache-button')),
      );
      await tester.pumpAndSettle();
      expect(clearedCache, 1);
      expect(find.text('已清除 3 章阅读缓存'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('export-diagnostics-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('diagnostics-preview')), findsOneWidget);
      expect(find.textContaining('version=1.2.3+45'), findsOneWidget);
      expect(find.textContaining('offlineDownloadBytes=4096'), findsOneWidget);
      String? copiedDiagnostics;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedDiagnostics =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('copy-diagnostics-button')));
      await tester.pumpAndSettle();
      expect(copiedDiagnostics, contains('JFZ Reader diagnostics'));
      expect(copiedDiagnostics, contains('cacheBytes=2048'));
    });

    testWidgets('checks for updates and exposes iOS sideload channels', (
      tester,
    ) async {
      const installed = AppVersion(name: '1.2.3', buildNumber: '45');
      final openedUris = <Uri>[];
      var checks = 0;
      String? copiedSource;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedSource =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpScreen(
        tester,
        SettingsScreen(
          appVersion: installed,
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          onClearSearchHistory: () {},
          onCheckForUpdate: () async {
            checks += 1;
            return AppUpdateCheck(
              installedVersion: installed,
              latestVersion: const AppVersion(name: '1.3.0', buildNumber: '46'),
              platform: AppUpdatePlatform.ios,
              updateAvailable: true,
              releasePageUri: Uri.parse(
                'https://github.com/example/repo/releases/tag/v1.3.0+46',
              ),
              artifact: AppUpdateArtifact(
                uri: Uri.parse(
                  'https://github.com/example/repo/releases/download/'
                  'v1.3.0+46/JFZ-Reader.ipa',
                ),
                size: 100,
                sha256: List.filled(64, 'a').join(),
              ),
              altStoreSourceUri: Uri.parse(
                'https://example.github.io/repo/altstore-source.json',
              ),
              releaseNotes: 'Improved update delivery.',
            );
          },
          onOpenUpdateLink: (uri) async => openedUris.add(uri),
        ),
      );

      expect(checks, 1);
      expect(find.text('1.2.3+45 · 新版本 1.3.0+46'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('open-releases-button')));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('Improved update delivery.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('copy-altstore-source')));
      await tester.pump();
      expect(
        copiedSource,
        'https://example.github.io/repo/altstore-source.json',
      );

      await tester.tap(find.byKey(const ValueKey('download-sideloadly-ipa')));
      await tester.pump();
      expect(openedUris.single.path, endsWith('.ipa'));
    });

    testWidgets('Android updates download in-app before opening installer', (
      tester,
    ) async {
      const installed = AppVersion(name: '1.2.3', buildNumber: '45');
      final openedUris = <Uri>[];
      final installer = _ControlledUpdateInstaller();
      final update = AppUpdateCheck(
        installedVersion: installed,
        latestVersion: const AppVersion(name: '1.3.0', buildNumber: '46'),
        platform: AppUpdatePlatform.android,
        updateAvailable: true,
        releasePageUri: Uri.parse(
          'https://github.com/example/repo/releases/tag/v1.3.0+46',
        ),
        artifact: AppUpdateArtifact(
          uri: Uri.parse(
            'https://github.com/example/repo/releases/download/'
            'v1.3.0+46/JFZ-Reader.apk',
          ),
          size: 100,
          sha256: List.filled(64, 'a').join(),
        ),
        altStoreSourceUri: Uri.parse(
          'https://example.github.io/repo/altstore-source.json',
        ),
      );

      await pumpScreen(
        tester,
        SettingsScreen(
          appVersion: installed,
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          onClearSearchHistory: () {},
          onCheckForUpdate: () async => update,
          updateInstaller: installer,
          onOpenUpdateLink: (uri) async => openedUris.add(uri),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('open-releases-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('download-platform-update')));
      await tester.pump();

      expect(installer.update, same(update));
      expect(openedUris, isEmpty);
      expect(
        find.byKey(const ValueKey('platform-update-progress')),
        findsOneWidget,
      );
      expect(find.text('正在下载 50%'), findsOneWidget);

      installer.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('platform-installer-opened')),
        findsOneWidget,
      );
    });

    testWidgets('macOS updates open Sparkle instead of the browser', (
      tester,
    ) async {
      const installed = AppVersion(name: '1.2.3', buildNumber: '45');
      final openedUris = <Uri>[];
      final installer = _ControlledUpdateInstaller();
      final update = AppUpdateCheck(
        installedVersion: installed,
        latestVersion: const AppVersion(name: '1.3.0', buildNumber: '46'),
        platform: AppUpdatePlatform.macos,
        updateAvailable: true,
        releasePageUri: Uri.parse(
          'https://github.com/example/repo/releases/tag/v1.3.0+46',
        ),
        artifact: AppUpdateArtifact(
          uri: Uri.parse(
            'https://github.com/example/repo/releases/download/'
            'v1.3.0+46/JFZ-Reader.dmg',
          ),
          size: 100,
          sha256: List.filled(64, 'a').join(),
        ),
        altStoreSourceUri: Uri.parse(
          'https://example.github.io/repo/altstore-source.json',
        ),
      );

      await pumpScreen(
        tester,
        SettingsScreen(
          appVersion: installed,
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          onClearSearchHistory: () {},
          onCheckForUpdate: () async => update,
          updateInstaller: installer,
          onOpenUpdateLink: (uri) async => openedUris.add(uri),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('open-releases-button')));
      await tester.pumpAndSettle();
      expect(find.text('使用 Sparkle 更新并重启 macOS 应用'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('download-platform-update')));
      await tester.pump();
      expect(installer.update, same(update));
      expect(openedUris, isEmpty);

      installer.complete();
      await tester.pumpAndSettle();
      expect(find.text('已打开 Sparkle 更新程序'), findsOneWidget);
    });
  });
}

class _ControlledUpdateInstaller implements AppUpdateInstaller {
  final _completion = Completer<void>();
  AppUpdateCheck? update;

  @override
  Future<void> install(
    AppUpdateCheck update, {
    AppUpdateProgressChanged? onProgress,
  }) {
    this.update = update;
    onProgress?.call(
      const AppUpdateInstallProgress(
        stage: AppUpdateInstallStage.downloading,
        receivedBytes: 50,
        totalBytes: 100,
      ),
    );
    return _completion.future;
  }

  void complete() => _completion.complete();
}
