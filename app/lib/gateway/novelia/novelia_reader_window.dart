import 'dart:async';

import '../../core/model/reader_models.dart';
import '../../features/discover/catalog_models.dart';
import 'novelia_content_coordinator.dart';
import 'novelia_gateway.dart';

/// Creates a bounded initial reader window and its dynamic chapter data source.
class NoveliaReaderWindowFactory {
  const NoveliaReaderWindowFactory({required this.contentCoordinator});

  final NoveliaContentCoordinator contentCoordinator;

  ReaderLaunchLoader loaderFor(TranslationSource translationSource) {
    return (novel, selectedChapter, requestedPosition) => create(
      novel: novel,
      selectedChapter: selectedChapter,
      requestedPosition: requestedPosition,
      translationSource: translationSource,
    );
  }

  Future<ReaderLaunchData> create({
    required CatalogNovel novel,
    required NovelChapter? selectedChapter,
    required ReadingPosition? requestedPosition,
    required TranslationSource translationSource,
  }) async {
    final hydrated = novel.readerNovel;
    if (hydrated == null) {
      throw ArgumentError.value(
        novel.id,
        'novel',
        'Reader windows require a hydrated chapter catalog.',
      );
    }

    final catalogChapters = _dedupeChapters(hydrated.chapters);
    final sectionByChapterId = _sectionTitles(novel.chapterSections);
    late final _NoveliaReaderWindowSession session;
    session = _NoveliaReaderWindowSession(
      contentCoordinator: contentCoordinator,
      novel: novel,
      translationSource: translationSource,
      chapters: catalogChapters,
      catalog: [
        for (final chapter in catalogChapters)
          ReaderChapterCatalogEntry.fromChapter(
            chapter,
            sectionTitle: sectionByChapterId[chapter.id],
          ),
      ],
    );

    if (catalogChapters.isEmpty) {
      return ReaderLaunchData(
        novel: ReaderNovel(
          id: hydrated.id,
          chineseTitle: hydrated.chineseTitle,
          japaneseTitle: hydrated.japaneseTitle,
          author: hydrated.author,
          chapters: const [],
        ),
        dataSource: session.dataSource,
      );
    }

    final catalogIds = {for (final chapter in catalogChapters) chapter.id};
    final requestedId = requestedPosition?.chapterId;
    final selectedId = selectedChapter?.id;
    final targetId = requestedId != null && catalogIds.contains(requestedId)
        ? requestedId
        : selectedId != null && catalogIds.contains(selectedId)
        ? selectedId
        : catalogChapters.first.id;
    final initialWindow = await session.loadAround(targetId);
    return ReaderLaunchData(
      novel: ReaderNovel(
        id: hydrated.id,
        chineseTitle: hydrated.chineseTitle,
        japaneseTitle: hydrated.japaneseTitle,
        author: hydrated.author,
        chapters: initialWindow.chapters,
      ),
      initialPosition: requestedId != null && catalogIds.contains(requestedId)
          ? requestedPosition
          : null,
      startAtChapterTitle:
          requestedId == null || !catalogIds.contains(requestedId),
      dataSource: session.dataSource,
    );
  }

  static List<NovelChapter> _dedupeChapters(Iterable<NovelChapter> chapters) {
    final ids = <String>{};
    return List.unmodifiable([
      for (final chapter in chapters)
        if (chapter.id.isNotEmpty && ids.add(chapter.id)) chapter,
    ]);
  }

  static Map<String, String> _sectionTitles(
    Iterable<CatalogChapterSection> sections,
  ) {
    final result = <String, String>{};
    for (final section in sections) {
      for (final chapterId in section.chapterIds) {
        result.putIfAbsent(chapterId, () => section.title);
      }
    }
    return result;
  }
}

class _NoveliaReaderWindowSession {
  static const _forwardPrefetchChapterCount = 3;

  _NoveliaReaderWindowSession({
    required this.contentCoordinator,
    required this.novel,
    required this.translationSource,
    required this.chapters,
    required this._catalog,
  }) : _indexById = {
         for (var index = 0; index < chapters.length; index++)
           chapters[index].id: index,
       };

  final NoveliaContentCoordinator contentCoordinator;
  final CatalogNovel novel;
  final TranslationSource translationSource;
  final List<NovelChapter> chapters;
  final List<ReaderChapterCatalogEntry> _catalog;
  final Map<String, int> _indexById;
  final Map<String, NovelChapter> _loaded = <String, NovelChapter>{};
  final Map<String, Future<NovelChapter?>> _loading =
      <String, Future<NovelChapter?>>{};
  final Set<String> _refreshing = <String>{};
  final Set<String> _unavailable = <String>{};

  late final ReaderChapterDataSource dataSource = ReaderChapterDataSource(
    catalog: _catalog,
    loadAround: loadAround,
    loadAdjacent: loadAdjacent,
  );

  Future<ReaderChapterWindow> loadAround(String chapterId) async {
    final targetIndex = _indexById[chapterId];
    if (targetIndex == null) {
      return const ReaderChapterWindow(
        chapters: [],
        before: ReaderBoundaryStatus.unavailable,
        after: ReaderBoundaryStatus.unavailable,
      );
    }

    final target = await _loadRequired(targetIndex);
    if (target == null) {
      return const ReaderChapterWindow(
        chapters: [],
        before: ReaderBoundaryStatus.unavailable,
        after: ReaderBoundaryStatus.unavailable,
      );
    }

    final beforeIndex = targetIndex - 1;
    final afterIndex = targetIndex + 1;
    final loadedByIndex = <int, NovelChapter>{targetIndex: target};
    if (beforeIndex >= 0) {
      final before = _loadCachedOptional(beforeIndex);
      if (before != null) loadedByIndex[beforeIndex] = before;
    }
    if (afterIndex < chapters.length) {
      final after = _loadCachedOptional(afterIndex);
      if (after != null) loadedByIndex[afterIndex] = after;
    }
    _scheduleForwardPrefetch(targetIndex);
    final indices = <int>[
      if (beforeIndex >= 0) beforeIndex,
      targetIndex,
      if (afterIndex < chapters.length) afterIndex,
    ];
    return ReaderChapterWindow(
      chapters: [for (final index in indices) ?loadedByIndex[index]],
      before: beforeIndex < 0
          ? ReaderBoundaryStatus.endOfCatalog
          : !loadedByIndex.containsKey(beforeIndex)
          ? _unavailable.contains(chapters[beforeIndex].id)
                ? ReaderBoundaryStatus.unavailable
                : ReaderBoundaryStatus.loadable
          : beforeIndex == 0
          ? ReaderBoundaryStatus.endOfCatalog
          : ReaderBoundaryStatus.loadable,
      after: afterIndex >= chapters.length
          ? ReaderBoundaryStatus.endOfCatalog
          : !loadedByIndex.containsKey(afterIndex)
          ? _unavailable.contains(chapters[afterIndex].id)
                ? ReaderBoundaryStatus.unavailable
                : ReaderBoundaryStatus.loadable
          : afterIndex == chapters.length - 1
          ? ReaderBoundaryStatus.endOfCatalog
          : ReaderBoundaryStatus.loadable,
    );
  }

  Future<ReaderChapterWindow> loadAdjacent(
    ReaderAdjacentRequest request,
  ) async {
    final anchorIndex = _indexById[request.anchorChapterId];
    if (anchorIndex == null) {
      return const ReaderChapterWindow(
        chapters: [],
        before: ReaderBoundaryStatus.unavailable,
        after: ReaderBoundaryStatus.unavailable,
      );
    }
    final delta = request.direction == ReaderLoadDirection.before ? -1 : 1;
    final neighborIndex = anchorIndex + delta;
    if (neighborIndex < 0 || neighborIndex >= chapters.length) {
      return ReaderChapterWindow(
        chapters: const [],
        before: request.direction == ReaderLoadDirection.before
            ? ReaderBoundaryStatus.endOfCatalog
            : _oppositeBoundary(anchorIndex, ReaderLoadDirection.before),
        after: request.direction == ReaderLoadDirection.after
            ? ReaderBoundaryStatus.endOfCatalog
            : _oppositeBoundary(anchorIndex, ReaderLoadDirection.after),
      );
    }

    final chapter = await _loadRequired(neighborIndex);
    if (chapter == null) {
      return ReaderChapterWindow(
        chapters: const [],
        before: request.direction == ReaderLoadDirection.before
            ? ReaderBoundaryStatus.unavailable
            : _oppositeBoundary(anchorIndex, ReaderLoadDirection.before),
        after: request.direction == ReaderLoadDirection.after
            ? ReaderBoundaryStatus.unavailable
            : _oppositeBoundary(anchorIndex, ReaderLoadDirection.after),
      );
    }
    _scheduleForwardPrefetch(neighborIndex);
    return ReaderChapterWindow(
      chapters: [chapter],
      before: neighborIndex == 0
          ? ReaderBoundaryStatus.endOfCatalog
          : ReaderBoundaryStatus.loadable,
      after: neighborIndex == chapters.length - 1
          ? ReaderBoundaryStatus.endOfCatalog
          : ReaderBoundaryStatus.loadable,
    );
  }

  Future<NovelChapter?> _loadRequired(int index) async {
    final metadata = chapters[index];
    final memory = _loaded[metadata.id];
    if (memory != null) return memory;

    final existing = _loading[metadata.id];
    if (existing != null) return existing;

    late final Future<NovelChapter?> loading;
    loading = _loadRequiredOnce(index).whenComplete(() {
      if (identical(_loading[metadata.id], loading)) {
        _loading.remove(metadata.id);
      }
    });
    _loading[metadata.id] = loading;
    return loading;
  }

  Future<NovelChapter?> _loadRequiredOnce(int index) async {
    final metadata = chapters[index];

    final cached = _readCached(metadata);
    if (cached != null) {
      _loaded[metadata.id] = cached;
      _unavailable.remove(metadata.id);
      _scheduleRefresh(metadata);
      return cached;
    }

    final response = await contentCoordinator.loadChapter(
      novel,
      chapterId: metadata.id,
      cacheTranslationSource: translationSource,
    );
    final loaded = response.data;
    if (loaded != null && loaded.id == metadata.id) {
      _loaded[metadata.id] = loaded;
      _unavailable.remove(metadata.id);
      return loaded;
    }
    if (_isRetryableChapterFailure(response)) {
      throw response.failure ??
          StateError('Chapter ${metadata.id} failed to load.');
    }
    _unavailable.add(metadata.id);
    return null;
  }

  static bool _isRetryableChapterFailure(
    NoveliaContentResult<NovelChapter> response,
  ) {
    if (response.data != null) return false;
    if (response.availability == CatalogAvailability.authenticationRequired) {
      return true;
    }
    final failure = response.failure;
    if (failure == null) return false;
    return failure.kind == NoveliaGatewayFailureKind.network ||
        failure.kind == NoveliaGatewayFailureKind.timeout ||
        failure.kind == NoveliaGatewayFailureKind.server;
  }

  void _scheduleForwardPrefetch(int anchorIndex) {
    final endExclusive = (anchorIndex + 1 + _forwardPrefetchChapterCount).clamp(
      0,
      chapters.length,
    );
    if (anchorIndex + 1 >= endExclusive) return;

    unawaited(
      Future<void>(() async {
        for (var index = anchorIndex + 1; index < endExclusive; index++) {
          try {
            // Fetch sequentially so ordinary reading gets a useful horizon
            // without producing a burst of chapter requests. An adjacent
            // reader request shares the same in-flight Future.
            if (await _loadRequired(index) == null) return;
          } on Object {
            // Prefetch is speculative. The boundary request remains the
            // visible retry/error path if this early request fails.
            return;
          }
        }
      }),
    );
  }

  NovelChapter? _loadCachedOptional(int index) {
    final metadata = chapters[index];
    final memory = _loaded[metadata.id];
    if (memory != null) return memory;
    final cached = _readCached(metadata);
    if (cached == null) return null;
    _loaded[metadata.id] = cached;
    _unavailable.remove(metadata.id);
    _scheduleRefresh(metadata);
    return cached;
  }

  NovelChapter? _readCached(NovelChapter metadata) {
    if (contentCoordinator is! NoveliaChapterCacheReader) return null;
    final cacheReader = contentCoordinator as NoveliaChapterCacheReader;
    final cached = cacheReader.cachedChapter(novel, chapterId: metadata.id);
    return cached != null && cached.id == metadata.id ? cached : null;
  }

  void _scheduleRefresh(NovelChapter metadata) {
    if (!_refreshing.add(metadata.id)) return;
    unawaited(
      Future<void>(() async {
        try {
          final response = await contentCoordinator.loadChapter(
            novel,
            chapterId: metadata.id,
            cacheTranslationSource: translationSource,
          );
          final refreshed = response.data;
          if (refreshed != null && refreshed.id == metadata.id) {
            final previous = _loaded[metadata.id];
            _loaded[metadata.id] = refreshed;
            _unavailable.remove(metadata.id);
            if (_chapterTranslationChanged(
              previous,
              refreshed,
              translationSource,
            )) {
              dataSource.notifyChapterUpdated(refreshed);
            }
          }
        } on Object {
          // Cached content is already readable; revalidation is best effort.
        } finally {
          _refreshing.remove(metadata.id);
        }
      }),
    );
  }

  static bool _chapterTranslationChanged(
    NovelChapter? previous,
    NovelChapter next,
    TranslationSource source,
  ) {
    if (previous == null) return true;
    if (previous.translationState(source) != next.translationState(source)) {
      return true;
    }
    if (previous.blocks.length != next.blocks.length) return true;
    for (var index = 0; index < previous.blocks.length; index++) {
      if (previous.blocks[index].translations[source] !=
          next.blocks[index].translations[source]) {
        return true;
      }
    }
    return false;
  }

  ReaderBoundaryStatus _oppositeBoundary(
    int anchorIndex,
    ReaderLoadDirection direction,
  ) {
    return switch (direction) {
      ReaderLoadDirection.before =>
        anchorIndex == 0
            ? ReaderBoundaryStatus.endOfCatalog
            : ReaderBoundaryStatus.loadable,
      ReaderLoadDirection.after =>
        anchorIndex == chapters.length - 1
            ? ReaderBoundaryStatus.endOfCatalog
            : ReaderBoundaryStatus.loadable,
    };
  }
}
