import 'dart:async';

import '../../core/model/reader_models.dart';
import '../../features/discover/catalog_models.dart';
import 'novelia_content_coordinator.dart';

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
    _unavailable.add(metadata.id);
    return null;
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
            _loaded[metadata.id] = refreshed;
            _unavailable.remove(metadata.id);
          }
        } on Object {
          // Cached content is already readable; revalidation is best effort.
        } finally {
          _refreshing.remove(metadata.id);
        }
      }),
    );
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
