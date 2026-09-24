import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/sqlite_offline_repository.dart';
import 'package:jfzreader/core/model/reader_models.dart';
import 'package:jfzreader/core/offline/content_models.dart';
import 'package:jfzreader/core/offline/offline_models.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_cache_adapter.dart';
import 'package:jfzreader/gateway/novelia/novelia_gateway.dart';

const offlineLatestNovelId = 'syosetu/offline-41';
const offlineLatestPosition = ReadingPosition(chapterId: 'c2', blockId: 'c2:1');

/// Sixteen older general titles and twenty-six newer R18 titles reproduce the
/// reported partial shelf. All identities, text, and timestamps are invented.
void seedOfflineLibrary(SqliteOfflineRepository repository) {
  final start = DateTime.utc(2026, 9, 1);
  const adapter = NoveliaContentCacheAdapter();
  for (var index = 0; index < 43; index++) {
    final now = start.add(Duration(hours: index));
    final id = 'syosetu/offline-$index';
    final outline = CachedNovelOutline(
      id: id,
      chineseTitle: index == 42 ? '仅缓存的最近阅读' : '离线小说 ${index + 1}',
      japaneseTitle: 'オフライン小説 ${index + 1}',
      author: '虚构作者',
      contentSource: 'Syosetu',
      publicationState: CachedNovelState.ongoing,
      chapterCount: 2,
      wordCount: 100,
      updatedAt: now,
      tags: [if (index >= 16) 'R18'],
      translationCoverage: const [],
      fetchedAt: now,
    );
    repository.upsertNovelDetail(
      CachedNovelDetail(
        outline: outline,
        synopsis: '用于离线重启回归测试的虚构小说。',
        points: null,
        views: null,
        originalUrl: null,
        sections: [
          CachedTocSection(
            id: 'body',
            title: '正文',
            chapters: [
              for (var chapter = 1; chapter <= 2; chapter++)
                CachedTocChapter(
                  id: 'c$chapter',
                  index: chapter - 1,
                  chineseTitle: '第$chapter章',
                  japaneseTitle: '第$chapter話',
                ),
            ],
          ),
        ],
      ),
    );
    final downloaded = index < 42;
    if (downloaded) {
      repository.saveIntent(
        NovelDownloadIntent(
          id: 'intent-$index',
          novelId: id,
          translationSource: TranslationSource.sakura,
          createdAt: now,
        ),
      );
      repository.reconcileIntent(
        intentId: 'intent-$index',
        knownChapterIds: const ['c1', 'c2'],
        now: now,
      );
    }
    for (var chapter = 1; chapter <= 2; chapter++) {
      final payload = CachedChapterPayload(
        id: '$id:c$chapter',
        novelId: id,
        chapterId: 'c$chapter',
        index: chapter - 1,
        chineseTitle: '第$chapter章',
        japaneseTitle: '第$chapter話',
        previousChapterId: chapter == 2 ? 'c1' : null,
        nextChapterId: chapter == 1 ? 'c2' : null,
        publishedAt: now,
        japaneseBlocks: const ['保存した物語。', 'ネットがなくても続きを読む。'],
        translations: {
          TranslationSource.sakura: CachedChapterTranslation(
            availability: TranslationAvailability.complete,
            blocks: const ['已经下载的故事。', '没有网络也能继续阅读。'],
          ),
        },
        fetchedAt: now,
      );
      if (downloaded) {
        final task = repository
            .listTasks(intentId: 'intent-$index')
            .singleWhere((task) => task.chapterId == 'c$chapter');
        final fetching = task.beginFetching(now);
        repository.saveTask(fetching);
        final validating = fetching.beginValidation(now);
        repository.saveTask(validating);
        final storing = validating.beginStoring(now);
        repository.saveTask(storing);
        repository.commitDownloadedChapter(
          taskId: task.id,
          payload: payload,
          copy: adapter.downloadedCopy(payload, task: storing, storedAt: now),
          now: now,
        );
      } else {
        repository.cacheChapterPayload(
          payload: payload,
          copy: adapter.cacheCopy(
            payload,
            translationSource: TranslationSource.sakura,
            storedAt: now,
          ),
        );
      }
    }
    repository.saveReadingProgress(
      LocalReadingProgress(
        novelId: id,
        position: const ReadingPosition(chapterId: 'c1', blockId: 'c1:0'),
        updatedAt: start,
      ),
    );
    repository.saveReadingProgress(
      LocalReadingProgress(
        novelId: id,
        position: offlineLatestPosition,
        updatedAt: now,
      ),
    );
    repository.saveBookmark(
      LocalBookmark(
        id: 'bookmark-$index',
        novelId: id,
        position: offlineLatestPosition,
        createdAt: now,
      ),
    );
  }
  repository.saveLastRoute(
    LastRouteState(routeName: '/library', updatedAt: start),
  );
}

class OfflineLibraryGateway implements NoveliaGateway {
  var contentRequests = 0;
  static const failure = NoveliaGatewayException(
    NoveliaGatewayFailureKind.network,
    'Fixture offline',
  );

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listNovels(
    NoveliaCatalogQuery query,
  ) async => throw failure;
  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listRankings(
    NoveliaRankingQuery query,
  ) async => throw failure;
  @override
  Future<NoveliaNovelDetails> getNovel(NoveliaNovelKey key) async {
    contentRequests++;
    throw failure;
  }

  @override
  Future<NoveliaChapterPayload> getChapter(
    NoveliaNovelKey key,
    String chapterId, {
    void Function(int, int?)? onReceiveProgress,
  }) async {
    contentRequests++;
    throw failure;
  }

  @override
  Future<NoveliaPage<NoveliaComment>> listComments(
    NoveliaNovelKey key, {
    int page = 0,
    int pageSize = 10,
  }) async => throw failure;
}
