import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/wenku/wenku_details_screen.dart';
import 'package:jfzreader/features/wenku/wenku_epub_document.dart';
import 'package:jfzreader/features/wenku/wenku_epub_store.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';

void main() {
  testWidgets('bilingual order is locked while an EPUB download is active', (
    tester,
  ) async {
    final gateway = _PendingDownloadGateway();
    const summary = WenkuNovelSummary(
      id: 'novel-1',
      japaneseTitle: '原題',
      chineseTitle: '译名',
      coverUri: null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: WenkuDetailsScreen(
          gateway: gateway,
          summary: summary,
          store: const _EmptyEpubStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SegmentedButton<WenkuBilingualOrder>>(
            find.byType(SegmentedButton<WenkuBilingualOrder>),
          )
          .onSelectionChanged,
      isNotNull,
    );

    await tester.ensureVisible(find.text('下载并阅读'));
    await tester.pump();
    await tester.tap(find.text('下载并阅读'));
    await tester.pump();

    expect(gateway.request?.order, WenkuBilingualOrder.chineseFirst);
    expect(
      tester
          .widget<SegmentedButton<WenkuBilingualOrder>>(
            find.byType(SegmentedButton<WenkuBilingualOrder>),
          )
          .onSelectionChanged,
      isNull,
    );

    gateway.cancel();
    await tester.pumpAndSettle();
  });
}

class _EmptyEpubStore extends WenkuEpubStore {
  const _EmptyEpubStore();

  @override
  Future<WenkuEpubDocument?> load(WenkuEpubRequest request) async => null;
}

class _PendingDownloadGateway implements NoveliaWenkuGateway {
  WenkuEpubRequest? request;
  Completer<Uint8List>? _result;

  void cancel() {
    final result = _result;
    if (result != null && !result.isCompleted) {
      result.completeError(const WenkuEpubDownloadCancelledException());
    }
  }

  @override
  Future<NoveliaPage<WenkuNovelSummary>> listNovels(WenkuCatalogQuery query) =>
      throw UnimplementedError();

  @override
  Future<WenkuNovelDetails> getNovel(String novelId) async =>
      const WenkuNovelDetails(
        id: 'novel-1',
        japaneseTitle: '原題',
        chineseTitle: '译名',
        coverUri: null,
        authors: [],
        artists: [],
        keywords: [],
        publisher: null,
        imprint: null,
        level: '轻小说',
        introduction: '简介',
        publishedVolumes: [],
        japaneseEpubs: [
          WenkuEpubVolume(
            volumeId: 'volume-1.epub',
            totalParagraphs: 1,
            translationCounts: {WenkuTranslationProvider.sakura: 1},
          ),
        ],
        chineseEpubIds: [],
      );

  @override
  Future<Uint8List> downloadEpub(
    WenkuEpubRequest request, {
    void Function(int bytesReceived, int? totalBytes)? onReceiveProgress,
    WenkuEpubDownloadCancellationToken? cancellationToken,
  }) {
    this.request = request;
    final result = Completer<Uint8List>();
    _result = result;
    cancellationToken?.addListener(cancel);
    return result.future;
  }
}
