import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
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
      await pumpScreen(
        tester,
        LibraryScreen(novels: fixtureCatalogNovels, onOpenNovel: (_) {}),
      );

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
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
          onClearSearchHistory: () {},
        ),
      );

      expect(find.text('0 B · 0 部小说 · 0 章'), findsOneWidget);
      expect(find.text('0 B · 0 章 · 上限未设置'), findsOneWidget);
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
  });
}
