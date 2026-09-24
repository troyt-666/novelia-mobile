import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/wenku/wenku_catalog_screen.dart';
import 'package:jfzreader/features/wenku/wenku_details_screen.dart';
import 'package:jfzreader/features/wenku/wenku_epub_document.dart';
import 'package:jfzreader/features/wenku/wenku_epub_store.dart';
import 'package:jfzreader/features/wenku/wenku_reader_screen.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';

import 'support/wenku_offline_fixture.dart';

void main() {
  for (final pending in [false, true]) {
    testWidgets(
      'local reading bypasses ${pending ? 'pending' : 'failed'} catalog requests',
      (tester) async {
        final gateway = _OfflineGateway(pending: pending);
        final store = _LocalStore();
        await tester.pumpWidget(
          MaterialApp(
            home: WenkuCatalogScreen(gateway: gateway, store: store),
          ),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('wenku-downloads-button')));
        await tester.pumpAndSettle();
        expect(find.text('已下载文库'), findsOneWidget);
        await tester.tap(find.text('离线列车'));
        await tester.pumpAndSettle();
        final reader = tester.widget<WenkuReaderScreen>(
          find.byType(WenkuReaderScreen),
        );
        expect(reader.document.title, '离线列车 · 第一卷');
        expect(reader.order, WenkuBilingualOrder.japaneseFirst);
        expect(gateway.detailCalls, 0);
        expect(gateway.downloadCalls, 0);
        expect(store.openCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed novel details still allow local reading', (tester) async {
    final gateway = _OfflineGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: WenkuDetailsScreen(
          gateway: gateway,
          summary: const WenkuNovelSummary(
            id: 'fixture',
            japaneseTitle: '物語',
            chineseTitle: '离线列车',
            coverUri: null,
          ),
          store: _LocalStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wenku-downloads-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('离线列车'));
    await tester.pumpAndSettle();
    expect(find.byType(WenkuReaderScreen), findsOneWidget);
    expect(gateway.detailCalls, 1);
    expect(gateway.downloadCalls, 0);
    expect(tester.takeException(), isNull);
  });
}

class _LocalStore extends WenkuEpubStore {
  int openCalls = 0;

  @override
  Future<WenkuReadingPosition?> readingPosition(String fileName) async =>
      const WenkuReadingPosition(spineIndex: 0, fraction: .5);

  @override
  Future<List<WenkuDownloadedEpub>> listDownloads() async => const [
    WenkuDownloadedEpub(
      fileName: 'fixture.epub',
      title: '离线列车',
      volumeId: '第一卷',
      order: WenkuBilingualOrder.japaneseFirst,
    ),
  ];

  @override
  Future<WenkuEpubDocument> openDownload(WenkuDownloadedEpub download) async {
    openCalls++;
    return WenkuEpubDocument.parse(wenkuOfflineEpub());
  }
}

class _OfflineGateway implements NoveliaWenkuGateway {
  _OfflineGateway({this.pending = false});
  final bool pending;
  int detailCalls = 0;
  int downloadCalls = 0;
  static const failure = NoveliaGatewayException(
    NoveliaGatewayFailureKind.network,
    '当前无法连接网络',
  );

  @override
  Future<NoveliaPage<WenkuNovelSummary>> listNovels(WenkuCatalogQuery query) =>
      pending
      ? Completer<NoveliaPage<WenkuNovelSummary>>().future
      : Future.error(failure);

  @override
  Future<WenkuNovelDetails> getNovel(String novelId) async {
    detailCalls++;
    throw failure;
  }

  @override
  Future<NoveliaPage<NoveliaComment>> listComments(
    String novelId, {
    int page = 0,
    int pageSize = 10,
  }) async => throw failure;

  @override
  Future<Uint8List> downloadEpub(
    WenkuEpubRequest request, {
    void Function(int bytesReceived, int? totalBytes)? onReceiveProgress,
    WenkuEpubDownloadCancellationToken? cancellationToken,
  }) async {
    downloadCalls++;
    throw failure;
  }
}
