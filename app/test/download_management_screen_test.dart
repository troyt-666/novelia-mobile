import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/features/shell/download_management_screen.dart';
import 'package:jfzreader/features/shell/shell_view_models.dart';
import 'package:jfzreader/fixtures/catalog_fixture.dart';

void main() {
  LibraryProtectedDownload download({required bool enabled}) {
    return LibraryProtectedDownload(
      novel: fixtureCatalogNovels.first,
      translationSource: TranslationSource.sakura,
      intentIds: const ['download-intent'],
      enabled: enabled,
      chapters: [
        LibraryDownloadChapter(
          chapterId: 'chapter-1',
          byteCount: 1024,
          translationAvailable: false,
          taskState: DownloadTaskState.failed,
          failure: DownloadFailure.insufficientStorage(
            requiredBytes: 4096,
            availableBytes: 1024,
          ),
        ),
      ],
    );
  }

  LibraryProtectedDownload progressDownload({
    required DownloadTaskState secondState,
    int secondBytesReceived = 0,
    bool enabled = true,
  }) {
    final secondStored = secondState == DownloadTaskState.stored;
    return LibraryProtectedDownload(
      novel: fixtureCatalogNovels.first,
      translationSource: TranslationSource.sakura,
      intentIds: const ['download-intent'],
      enabled: enabled,
      chapters: [
        LibraryDownloadChapter(
          chapterId: 'chapter-1',
          byteCount: 100,
          translationAvailable: true,
          taskState: DownloadTaskState.stored,
          bytesReceived: 100,
          totalBytes: 100,
        ),
        LibraryDownloadChapter(
          chapterId: 'chapter-2',
          byteCount: secondStored ? 100 : 0,
          translationAvailable: secondStored,
          taskState: secondState,
          bytesReceived: secondBytesReceived,
          totalBytes: secondState == DownloadTaskState.queued ? null : 100,
        ),
      ],
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    required DownloadManagementHandler onAction,
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagementScreen(
          downloads: [download(enabled: true)],
          onAction: onAction,
          onOpenNovel: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows truthful failure details and applies pause/resume state', (
    tester,
  ) async {
    final actions = <DownloadManagementAction>[];
    await pumpScreen(
      tester,
      onAction: (action, current) async {
        actions.add(action);
        return download(enabled: action == DownloadManagementAction.resume);
      },
    );
    final groupKey = download(enabled: true).groupKey;

    expect(find.textContaining('存储空间不足'), findsOneWidget);
    expect(find.textContaining('需要 4.00 KB'), findsOneWidget);
    expect(find.textContaining('可用 1.00 KB'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('pause-download-$groupKey')));
    await tester.pumpAndSettle();
    expect(actions, [DownloadManagementAction.pause]);
    expect(find.byKey(ValueKey('resume-download-$groupKey')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('resume-download-$groupKey')));
    await tester.pumpAndSettle();
    expect(actions, [
      DownloadManagementAction.pause,
      DownloadManagementAction.resume,
    ]);
    expect(find.byKey(ValueKey('pause-download-$groupKey')), findsOneWidget);
  });

  testWidgets('requires confirmation before deleting the protected content', (
    tester,
  ) async {
    final actions = <DownloadManagementAction>[];
    await pumpScreen(
      tester,
      onAction: (action, current) async {
        actions.add(action);
        return null;
      },
    );
    final groupKey = download(enabled: true).groupKey;

    await tester.tap(find.byKey(ValueKey('remove-download-$groupKey')));
    await tester.pumpAndSettle();
    expect(find.text('删除离线下载？'), findsOneWidget);
    expect(find.textContaining('阅读进度和书签会保留'), findsOneWidget);
    expect(actions, isEmpty);

    await tester.tap(find.byKey(const ValueKey('confirm-remove-download')));
    await tester.pumpAndSettle();
    expect(actions, [DownloadManagementAction.remove]);
    expect(
      find.byKey(const ValueKey('downloads-management-empty')),
      findsOneWidget,
    );
  });

  testWidgets('refreshes live snapshots and exposes download progress phases', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var current = progressDownload(secondState: DownloadTaskState.queued);
    final groupKey = current.groupKey;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagementScreen(
          downloads: [current],
          snapshotLoader: () => [current],
          refreshInterval: const Duration(milliseconds: 10),
          onAction: (action, download) async => download,
          onOpenNovel: (_) {},
        ),
      ),
    );
    await tester.pump();

    LinearProgressIndicator progress() =>
        tester.widget<LinearProgressIndicator>(
          find.byKey(ValueKey('download-progress-$groupKey')),
        );

    expect(progress().value, 0.5);
    expect(find.text('1 / 2 章 · 50%'), findsOneWidget);
    expect(find.textContaining('chapter-2 · 等待下载'), findsOneWidget);

    current = progressDownload(
      secondState: DownloadTaskState.fetching,
      secondBytesReceived: 50,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    expect(progress().value, 0.75);
    expect(find.text('1 / 2 章 · 75%'), findsOneWidget);
    expect(find.text('下载中'), findsOneWidget);
    expect(
      find.textContaining('chapter-2 · 正在下载 · 50 B / 100 B'),
      findsOneWidget,
    );

    current = progressDownload(
      secondState: DownloadTaskState.stored,
      enabled: false,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    expect(progress().value, 1);
    expect(find.text('2 / 2 章 · 100%'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.byKey(ValueKey('download-current-$groupKey')), findsNothing);
    expect(find.byKey(ValueKey('pause-download-$groupKey')), findsNothing);
    expect(find.byKey(ValueKey('resume-download-$groupKey')), findsNothing);
    expect(find.byKey(ValueKey('remove-download-$groupKey')), findsOneWidget);
  });
}
