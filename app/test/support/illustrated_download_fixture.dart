import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_illustration_loader.dart';

import 'offline_library_fixture.dart';

const illustratedKey = NoveliaNovelKey(
  providerId: 'syosetu',
  novelId: 'offline-images',
);
final illustrationTime = DateTime.utc(2026, 9, 24);

class FixtureHttpOverrides extends HttpOverrides {}

void addIllustratedIntent(SqliteOfflineRepository repository) =>
    repository.saveIntent(
      NovelDownloadIntent(
        id: 'images',
        novelId: illustratedKey.stableId,
        translationSource: TranslationSource.sakura,
        createdAt: illustrationTime,
      ),
    );

class IllustratedDownloadGateway extends OfflineLibraryGateway {
  IllustratedDownloadGateway(this.url);
  final String url;
  bool offline = false;
  int chapterRequests = 0;

  @override
  Future<NoveliaNovelDetails> getNovel(NoveliaNovelKey key) async {
    if (offline) throw OfflineLibraryGateway.failure;
    return NoveliaNovelDetails(
      key: illustratedKey,
      japaneseTitle: '挿絵のある物語',
      chineseTitle: '有插图的离线故事',
      authors: const [NoveliaAuthor(name: '虚构作者')],
      publicationType: '连载中',
      attentions: const ['R18'],
      keywords: const [],
      points: 0,
      totalCharacters: 100,
      japaneseIntroduction: '紹介',
      chineseIntroduction: '离线图片验证',
      toc: [
        NoveliaTocEntry(
          japaneseTitle: '第一話',
          chineseTitle: '第一章',
          chapterId: 'c1',
          createdAt: illustrationTime,
        ),
      ],
      visited: 0,
      syncedAt: illustrationTime,
      originalChapters: 1,
      baiduChapters: 0,
      youdaoChapters: 1,
      gptChapters: 1,
      sakuraChapters: 1,
    );
  }

  @override
  Future<NoveliaChapterPayload> getChapter(
    NoveliaNovelKey key,
    String chapterId, {
    void Function(int, int?)? onReceiveProgress,
  }) async {
    chapterRequests++;
    if (offline) throw OfflineLibraryGateway.failure;
    final blocks = ['<图片>$url', '断网以后，插图和文字都应保留。', '<图片>$url'];
    return NoveliaChapterPayload(
      key: illustratedKey,
      chapterId: 'c1',
      japaneseTitle: '第一話',
      chineseTitle: '第一章',
      novelJapaneseTitle: '挿絵のある物語',
      novelChineseTitle: '有插图的离线故事',
      previousChapterId: null,
      nextChapterId: null,
      originalParagraphs: blocks,
      baiduParagraphs: const [],
      youdaoParagraphs: blocks,
      gptParagraphs: blocks,
      sakuraParagraphs: blocks,
    );
  }
}

class FixtureIllustrationLoader implements NoveliaIllustrationLoader {
  FixtureIllustrationLoader(this.bytes);
  final Uint8List bytes;
  int calls = 0;
  bool fail = false;
  Future<void>? gate;
  @override
  Future<Uint8List> load(Uri uri) async {
    calls++;
    await gate;
    if (fail) throw OfflineLibraryGateway.failure;
    return bytes;
  }
}

Future<Uint8List> offlineIllustrationPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xFFD2EBDD), ui.BlendMode.src);
  final paint = ui.Paint()..color = const ui.Color(0xFF397B62);
  canvas.drawRect(const ui.Rect.fromLTWH(40, 25, 95, 130), paint);
  canvas.drawRect(const ui.Rect.fromLTWH(145, 25, 95, 130), paint);
  paint.color = const ui.Color(0xFFF4F8EE);
  for (var line = 0; line < 5; line++) {
    canvas.drawRect(ui.Rect.fromLTWH(55, 44 + line * 20, 65, 5), paint);
    canvas.drawRect(ui.Rect.fromLTWH(160, 44 + line * 20, 65, 5), paint);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(280, 180);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}
