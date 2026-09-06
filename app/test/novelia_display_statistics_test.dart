import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/features/novel_details/novel_details_screen.dart';
import 'package:jfzreader/gateway/novelia/http_novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_domain_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';

void main() {
  const codec = NoveliaJsonCodec();
  const adapter = NoveliaDomainAdapter();
  const cache = NoveliaContentCacheAdapter();
  const key = NoveliaNovelKey(providerId: 'syosetu', novelId: 'novel1');

  test(
    'invalid coverage does not discard valid sources or neighboring novels',
    () {
      final page = codec.decodeNovelPage({
        'pageNumber': 1,
        'items': [
          for (final total in [2, -1, 3])
            {
              ..._metadata,
              'providerId': 'syosetu',
              'novelId': 'novel$total',
              'total': total,
              'youdao': 3,
              'gpt': 0,
              'sakura': 2,
            },
        ],
      });
      final novels = adapter.mapGeneralOutlines(page.items);
      expect(novels, hasLength(3));
      final unknown = novels.first.coverageFor('有道')!;
      expect(unknown.label, '有道 统计未知');
      expect(unknown.hasTranslation, isFalse);
      expect(unknown.isComplete, isFalse);
      expect(novels.first.coverageFor('GPT')!.label, 'GPT 0/2');
      expect(novels.first.coverageFor('Sakura')!.isComplete, isTrue);
      expect(novels[1].knownChapterCount, isNull);
      expect(
        novels[1].translationCoverage.every((row) => !row.isKnown),
        isTrue,
      );
      expect(novels.last.coverageFor('有道')!.label, '有道 3/3');
    },
  );

  test(
    'bad detail statistics preserve TOC and round-trip as unknown in SQLite',
    () {
      final novel = adapter.mapDetails(codec.decodeNovel(key, _details()));
      expect(novel.wordCount, isNull);
      expect(novel.points, isNull);
      expect(novel.views, isNull);
      expect(novel.knownChapterCount, 1);
      expect(novel.readerNovel!.chapters.single.id, 'c1');
      final repository = SqliteOfflineRepository.openInMemory();
      addTearDown(repository.close);
      repository.upsertNovelDetail(
        cache.cacheDetails(novel, fetchedAt: DateTime.utc(2026, 9, 6)),
      );
      final restored = cache.restoreDetails(
        repository.novelDetail(key.stableId)!,
      );
      expect(restored.coverageFor('Sakura')!.label, 'Sakura 统计未知');
      expect(restored.points, isNull);
      expect(restored.knownChapterCount, 1);
      expect(restored.readerNovel!.chapters.single.id, 'c1');

      // Display tolerance cannot hide a structurally ambiguous TOC.
      final duplicateToc = _details();
      duplicateToc['toc'] = [
        {'titleJp': '章', 'chapterId': 'c1'},
        {'titleJp': '章', 'chapterId': 'c1'},
      ];
      expect(
        () => adapter.mapDetails(codec.decodeNovel(key, duplicateToc)),
        throwsA(isA<NoveliaDomainMappingException>()),
      );
    },
  );

  testWidgets(
    'unknown coverage renders without a progress bar and keeps reading available',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final novel = adapter.mapDetails(codec.decodeNovel(key, _details()));
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: NovelDetailsScreen(
            novel: novel,
            onOpenReader: (_) => opened = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('统计未知'), findsNWidgets(3));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.tap(find.text('开始阅读'));
      expect(opened, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

const _metadata = {
  'titleJp': '原文',
  'titleZh': '译文',
  'attentions': <String>[],
  'keywords': <String>[],
};

Map<String, Object?> _details() => {
  ..._metadata,
  'authors': <Object>[],
  'introductionJp': '简介',
  'toc': [
    {'titleJp': '章', 'chapterId': 'c1'},
  ],
  'jp': -1,
  'youdao': -1,
  'gpt': 0,
  'sakura': 10,
  'points': -1,
  'visited': -1,
  'totalCharacters': -1,
};
