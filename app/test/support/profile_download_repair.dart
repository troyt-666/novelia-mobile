import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_download_coordinator.dart';
import 'package:jfzreader/gateway/novelia/novelia_illustration_loader.dart';

import 'offline_library_fixture.dart';

/// Exercises the real old-download image repair/storage path while a separate
/// novel is being read. All books and images are generated in a temporary DB.
class ProfileDownloadRepair {
  ProfileDownloadRepair._(this.repository, this._loader);

  final SqliteOfflineRepository repository;
  final _RepairImageLoader _loader;

  static Future<ProfileDownloadRepair> seed(
    SqliteOfflineRepository repository,
  ) async {
    seedOfflineLibrary(repository);
    const adapter = NoveliaContentCacheAdapter();
    for (var i = 0; i < 24; i++) {
      final old = repository.chapterPayloadById('syosetu/offline-$i:c1')!;
      final payload = CachedChapterPayload(
        id: old.id,
        novelId: old.novelId,
        chapterId: old.chapterId,
        index: old.index,
        chineseTitle: old.chineseTitle,
        japaneseTitle: old.japaneseTitle,
        previousChapterId: old.previousChapterId,
        nextChapterId: old.nextChapterId,
        publishedAt: old.publishedAt,
        japaneseBlocks: [
          ...old.japaneseBlocks,
          '<图片>https://fixture.invalid/$i.png',
        ],
        translations: {
          for (final entry in old.translations.entries)
            entry.key: CachedChapterTranslation(
              availability: entry.value.availability,
              blocks: [
                ...entry.value.blocks,
                '<图片>https://fixture.invalid/$i.png',
              ],
            ),
        },
        fetchedAt: old.fetchedAt,
      );
      repository.cacheChapterPayload(
        payload: payload,
        copy: adapter.cacheCopy(
          payload,
          translationSource: TranslationSource.sakura,
          storedAt: old.fetchedAt,
        ),
      );
    }
    return ProfileDownloadRepair._(
      repository,
      _RepairImageLoader(await _image()),
    );
  }

  int get imageBytes => _loader.bytes.length;
  int get completedImages => _loader.calls;

  Future<void> run() async {
    final coordinator = AsyncNoveliaDownloadCoordinator(
      gateway: OfflineLibraryGateway(),
      contentRepository: repository,
      offlineRepository: repository,
      illustrationLoader: _loader,
    );
    for (var i = 0; i < 24; i++) {
      await coordinator.synchronizeIntent('intent-$i');
    }
  }
}

class _RepairImageLoader implements NoveliaIllustrationLoader {
  _RepairImageLoader(this.bytes);
  final Uint8List bytes;
  int calls = 0;
  @override
  Future<Uint8List> load(Uri uri) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    calls++;
    return bytes;
  }
}

Future<Uint8List> _image() async {
  // Deterministic grayscale noise gives a valid, non-trivially compressed PNG
  // (unlike flat fixture artwork). Compression size is recorded in the report.
  const width = int.fromEnvironment(
    'PROFILE_REPAIR_IMAGE_WIDTH',
    defaultValue: 1200,
  );
  const height = int.fromEnvironment(
    'PROFILE_REPAIR_IMAGE_HEIGHT',
    defaultValue: 1600,
  );
  final pixels = Uint8List(width * height * 4);
  var seed = 47;
  for (var i = 0; i < pixels.length; i += 4) {
    seed = (seed * 1664525 + 1013904223) & 0xffffffff;
    final shade = seed >> 24;
    pixels[i] = pixels[i + 1] = pixels[i + 2] = shade;
    pixels[i + 3] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
