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
}
