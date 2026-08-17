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

    final indices = <int>[
      if (targetIndex > 0) targetIndex - 1,
      targetIndex,
      if (targetIndex + 1 < chapters.length) targetIndex + 1,
    ];
    final loadedByIndex = await _loadIndices(indices);
    if (!loadedByIndex.containsKey(targetIndex)) {
      return const ReaderChapterWindow(
        chapters: [],
        before: ReaderBoundaryStatus.unavailable,
        after: ReaderBoundaryStatus.unavailable,
      );
    }

    final beforeIndex = targetIndex - 1;
    final afterIndex = targetIndex + 1;
    return ReaderChapterWindow(
      chapters: [for (final index in indices) ?loadedByIndex[index]],
      before: beforeIndex < 0
          ? ReaderBoundaryStatus.endOfCatalog
          : !loadedByIndex.containsKey(beforeIndex)
          ? ReaderBoundaryStatus.unavailable
          : beforeIndex == 0
          ? ReaderBoundaryStatus.endOfCatalog
          : ReaderBoundaryStatus.loadable,
      after: afterIndex >= chapters.length
          ? ReaderBoundaryStatus.endOfCatalog
          : !loadedByIndex.containsKey(afterIndex)
          ? ReaderBoundaryStatus.unavailable
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

    final loaded = await _loadIndices([neighborIndex]);
    final chapter = loaded[neighborIndex];
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

  Future<Map<int, NovelChapter>> _loadIndices(Iterable<int> indices) async {
    final result = <int, NovelChapter>{};
    for (final index in indices) {
      final metadata = chapters[index];
      var loaded = _loaded[metadata.id];
      if (loaded == null) {
        final response = await contentCoordinator.loadChapter(
          novel,
          chapterId: metadata.id,
          cacheTranslationSource: translationSource,
        );
        loaded = response.data;
        if (loaded != null && loaded.id == metadata.id) {
          _loaded[metadata.id] = loaded;
        } else {
          loaded = null;
        }
      }
      if (loaded != null) result[index] = loaded;
    }
    return result;
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
