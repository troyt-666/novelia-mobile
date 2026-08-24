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
