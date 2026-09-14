import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/features/discover/catalog_models.dart';
import 'package:jfzreader/features/shell/shell_view_models.dart';

/// Invented, deterministic books for widget and native layout checks.
class LibraryFixture {
  LibraryFixture(int count) {
    const titles = [
      '星港夜行列车',
      '齿轮图书馆的守夜人',
      '云上庭园的邮差',
      '雨声炼金术师',
      '被遗忘的图书馆与写在世界尽头的最后一封长信',
    ];
    novels = List.generate(count, (index) {
      final id = 'shelf-fixture-$index';
      final title =
          '${titles[index % titles.length]}${index < 5 ? '' : ' · $index'}';
      final reader = ReaderNovel(
        id: id,
        chineseTitle: title,
        japaneseTitle: '星の図書館から届いた手紙',
        author: '虚构作者',
        chapters: List.generate(
          2,
          (chapter) => NovelChapter(
            id: '$id-chapter-$chapter',
            index: chapter,
            publishedAt: null,
            chineseTitle: chapter == 0 ? '启程' : '寄往晴天的信',
            japaneseTitle: '晴れの日への手紙',
            blocks: [
              AlignedBlock(
                id: '$id-block-$chapter',
                ordinal: 0,
                japanese: '星の光が窓から差し込んだ。',
                translations: {
                  for (final source in TranslationSource.values)
                    source: '星光从窗外照进来。',
                },
              ),
            ],
          ),
        ),
      );
      return CatalogNovel(
        id: id,
        chineseTitle: title,
        japaneseTitle: reader.japaneseTitle,
        author: reader.author,
        source: 'Kakuyomu',
        publicationState: NovelPublicationState.ongoing,
        tags: const [],
        translationCoverage: const [],
        readerNovel: reader,
      );
    });
    reads = [
      for (var index = 0; index < novels.length; index++)
        LibraryContinuedRead(
          novel: novels[index],
          position: ReadingPosition(
            chapterId: '${novels[index].id}-chapter-0',
            blockId: '${novels[index].id}-block-0',
          ),
          progress: ((index % 8) + 1) / 10,
          chapterLabel: '第一章 · 启程',
        ),
    ];
    downloads = [
      for (var index = 0; index < novels.length; index++)
        download(novels[index], index),
      if (novels.isNotEmpty)
        download(novels.first, 0, source: TranslationSource.gpt),
    ];
  }

  late final List<CatalogNovel> novels;
  late final List<LibraryContinuedRead> reads;
  late final List<LibraryProtectedDownload> downloads;

  static LibraryProtectedDownload download(
    CatalogNovel novel,
    int index, {
    TranslationSource source = TranslationSource.sakura,
  }) {
    final state = switch (index % 5) {
      0 => DownloadTaskState.stored,
      1 => DownloadTaskState.fetching,
      2 => DownloadTaskState.failed,
      3 => DownloadTaskState.paused,
      _ => DownloadTaskState.queued,
    };
    return LibraryProtectedDownload(
      novel: novel,
      translationSource: source,
      intentIds: ['fixture-intent-${novel.id}-${source.name}'],
      enabled: state != DownloadTaskState.paused,
      chapters: [
        for (var chapter = 0; chapter < 2; chapter++)
          LibraryDownloadChapter(
            chapterId: '${novel.id}-chapter-$chapter',
            byteCount: chapter == 0 ? 2048 : 0,
            translationAvailable: index % 5 != 4,
            taskState: chapter == 0 && index % 5 != 4
                ? DownloadTaskState.stored
                : state,
          ),
      ],
    );
  }
}
