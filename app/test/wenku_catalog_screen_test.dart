import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/wenku/wenku_catalog_screen.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';

void main() {
  testWidgets('Wenku catalog exposes and submits every site level filter', (
    tester,
  ) async {
    final gateway = _RecordingWenkuGateway();
    await tester.pumpWidget(
      MaterialApp(home: WenkuCatalogScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    expect(gateway.queries.single.level, WenkuCatalogLevel.all);
    for (final level in WenkuCatalogLevel.values) {
      expect(find.text(level.label), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('wenku-level-lightLiterature')));
    await tester.pumpAndSettle();

    expect(gateway.queries.last.level, WenkuCatalogLevel.lightLiterature);
  });

  testWidgets('Wenku catalog appends subsequent service pages', (tester) async {
    final gateway = _PagingWenkuGateway();
    await tester.pumpWidget(
      MaterialApp(home: WenkuCatalogScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一部'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wenku-load-more-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('wenku-load-more-button')));
    await tester.pumpAndSettle();

    expect(gateway.queries.map((query) => query.page), [0, 1]);
    expect(find.text('第一部'), findsOneWidget);
    expect(find.text('第二部'), findsOneWidget);
    expect(find.byKey(const ValueKey('wenku-load-more-button')), findsNothing);
  });
}

class _RecordingWenkuGateway implements NoveliaWenkuGateway {
  final queries = <WenkuCatalogQuery>[];

  @override
  Future<NoveliaPage<WenkuNovelSummary>> listNovels(
    WenkuCatalogQuery query,
  ) async {
    queries.add(query);
    return const NoveliaPage(items: [], pageCount: 1);
  }

  @override
  Future<WenkuNovelDetails> getNovel(String novelId) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> downloadEpub(
    WenkuEpubRequest request, {
    void Function(int bytesReceived, int? totalBytes)? onReceiveProgress,
    WenkuEpubDownloadCancellationToken? cancellationToken,
  }) => throw UnimplementedError();
}

class _PagingWenkuGateway implements NoveliaWenkuGateway {
  final queries = <WenkuCatalogQuery>[];

  @override
  Future<NoveliaPage<WenkuNovelSummary>> listNovels(
    WenkuCatalogQuery query,
  ) async {
    queries.add(query);
    return NoveliaPage(
      items: [
        WenkuNovelSummary(
          id: 'novel-${query.page}',
          japaneseTitle: query.page == 0 ? '第一作' : '第二作',
          chineseTitle: query.page == 0 ? '第一部' : '第二部',
          coverUri: null,
        ),
      ],
      pageCount: 2,
    );
  }

  @override
  Future<WenkuNovelDetails> getNovel(String novelId) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> downloadEpub(
    WenkuEpubRequest request, {
    void Function(int bytesReceived, int? totalBytes)? onReceiveProgress,
    WenkuEpubDownloadCancellationToken? cancellationToken,
  }) => throw UnimplementedError();
}
