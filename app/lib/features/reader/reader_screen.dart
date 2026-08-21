import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent, ScrollDirection;

import '../../core/model/reader_models.dart';

typedef ReaderBookmarkChanged =
    void Function(ReadingPosition position, bool bookmarked);

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    required this.novel,
    required this.themeMode,
    required this.onThemeModeChanged,
    this.initialPosition,
    this.onPositionChanged,
    this.onExitPosition,
    this.initialBookmarkedBlockIds = const {},
    this.onBookmarkChanged,
    this.initialSettings = const ReaderSettings(),
    this.onSettingsChanged,
    this.chapterDataSource,
    super.key,
  });

  final ReaderNovel novel;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ReadingPosition? initialPosition;
  final ValueChanged<ReadingPosition>? onPositionChanged;
  final ValueChanged<ReadingPosition>? onExitPosition;
  final Set<String> initialBookmarkedBlockIds;
  final ReaderBookmarkChanged? onBookmarkChanged;
  final ReaderSettings initialSettings;
  final ValueChanged<ReaderSettings>? onSettingsChanged;
  final ReaderChapterDataSource? chapterDataSource;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with RestorationMixin, WidgetsBindingObserver {
  static const _boundaryTriggerExtent = 640.0;
  static const _boundaryRearmExtent = 1400.0;
  static const _initialWindowItems = 128;
  static const _windowExpansionItems = 96;
  static const _jumpLeadInItems = 2;
  static const _windowLeadInItems = 24;
  static const _chromeAutoHideDelay = Duration(seconds: 4);

  late List<NovelChapter> _loadedChapters;
  late List<ReaderStreamItem> _items;
  late Map<String, int> _itemIndices;
  final Map<String, GlobalKey> _itemKeys = {};
  final Map<String, BuildContext> _mountedItemContexts = {};
  final _scrollController = ScrollController();
  final _viewportKey = GlobalKey(debugLabel: 'reader-viewport');
  final _anchorBlockId = RestorableStringN(null);
  late final RestorableInt _modeIndex;
  late final RestorableInt _sourceIndex;
  late final RestorableDouble _chineseFontSize;
  late final RestorableDouble _japaneseFontSize;
  late final RestorableDouble _lineHeight;
  late final RestorableDouble _japaneseOpacity;
  late final RestorableDouble _readingWidth;
  final Set<String> _bookmarks = {};
  final Set<String> _mountedBlockIds = {};

  late ReaderSettings _settings;
  bool _chromeVisible = true;
  bool _restoring = true;
  bool _adjustingWindow = false;
  bool _preservingDynamicAnchor = false;
  bool _beforeLoading = false;
  bool _afterLoading = false;
  bool _beforeRequestArmed = true;
  bool _afterRequestArmed = true;
  Object? _beforeLoadError;
  Object? _afterLoadError;
  late ReaderBoundaryStatus _beforeBoundary;
  late ReaderBoundaryStatus _afterBoundary;
  bool _catalogLoading = false;
  Object? _catalogLoadError;
  ReaderChapterCatalogEntry? _catalogRetryEntry;
  var _windowGeneration = 0;
  String? _activeChapterId;
  ReadingPosition? _lastPosition;
  var _windowStart = 0;
  var _windowEnd = 0;
  int? _tapPointer;
  Offset? _tapOrigin;
  DateTime? _tapStartedAt;
  Timer? _chromeDismissTimer;

  @override
  String? get restorationId => 'reader:${widget.novel.id}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settings = widget.initialSettings;
    _modeIndex = RestorableInt(_settings.readingMode.index);
    _sourceIndex = RestorableInt(_settings.translationSource.index);
    _chineseFontSize = RestorableDouble(_settings.chineseFontSize);
    _japaneseFontSize = RestorableDouble(_settings.japaneseFontSize);
    _lineHeight = RestorableDouble(_settings.lineHeight);
    _japaneseOpacity = RestorableDouble(_settings.japaneseOpacity);
    _readingWidth = RestorableDouble(_settings.readingWidth);
    _loadedChapters = List.of(widget.novel.chapters);
    _rebuildStream();
    final initialBoundaries = _initialBoundaryStatuses();
    _beforeBoundary = initialBoundaries.$1;
    _afterBoundary = initialBoundaries.$2;
    _windowEnd = _items.length.clamp(0, _initialWindowItems);
    _bookmarks.addAll(widget.initialBookmarkedBlockIds);
    _activeChapterId =
        widget.initialPosition?.chapterId ??
        (_loadedChapters.isEmpty ? null : _loadedChapters.first.id);
    _lastPosition = _resolvedInitialPosition();
    widget.chapterDataSource?.addChapterUpdateListener(_onChapterUpdated);
  }

  @override
  void didUpdateWidget(ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapterDataSource == widget.chapterDataSource) return;
    oldWidget.chapterDataSource?.removeChapterUpdateListener(_onChapterUpdated);
    widget.chapterDataSource?.addChapterUpdateListener(_onChapterUpdated);
  }

  void _onChapterUpdated(NovelChapter chapter) {
    if (!mounted) return;
    final index = _loadedChapters.indexWhere((item) => item.id == chapter.id);
    if (index < 0) return;
    if (identical(_loadedChapters[index], chapter)) return;
    setState(() {
      _loadedChapters[index] = chapter;
      _rebuildStream();
    });
  }

  List<ReaderChapterCatalogEntry> get _chapterCatalog {
    final remoteCatalog = widget.chapterDataSource?.catalog;
    if (remoteCatalog != null) return remoteCatalog;
    return [
      for (final chapter in _loadedChapters)
        ReaderChapterCatalogEntry.fromChapter(chapter),
    ];
  }

  void _rebuildStream() {
    final order = {
      for (var index = 0; index < _chapterCatalog.length; index++)
        _chapterCatalog[index].id: index,
    };
    _loadedChapters.sort((a, b) {
      final aOrder = order[a.id];
      final bOrder = order[b.id];
      if (aOrder != null && bOrder != null) return aOrder.compareTo(bOrder);
      if (aOrder != null) return -1;
      if (bOrder != null) return 1;
      return a.index.compareTo(b.index);
    });
    _items = ReaderNovel(
      id: widget.novel.id,
      chineseTitle: widget.novel.chineseTitle,
      japaneseTitle: widget.novel.japaneseTitle,
      author: widget.novel.author,
      chapters: _loadedChapters,
    ).buildStream();
    final stableIds = <String>{};
    for (final item in _items) {
      if (!stableIds.add(item.stableId)) {
        throw StateError('阅读窗口包含重复的语义位置：${item.stableId}');
      }
    }
    _itemIndices = {
      for (var index = 0; index < _items.length; index++)
        _items[index].stableId: index,
    };
    for (final item in _items) {
      if (item is ChapterBoundaryItem) {
        _itemKeys.putIfAbsent(
          item.stableId,
          () => GlobalKey(debugLabel: item.stableId),
        );
      }
    }
  }

  BuildContext? _mountedContextFor(String stableId) {
    final mountedContext = _mountedItemContexts[stableId];
    if (mountedContext != null && mountedContext.mounted) {
      return mountedContext;
    }
    final keyedContext = _itemKeys[stableId]?.currentContext;
    return keyedContext != null && keyedContext.mounted ? keyedContext : null;
  }

  void _registerMountedItem(String stableId, BuildContext itemContext) {
    _mountedItemContexts[stableId] = itemContext;
  }

  void _unregisterMountedItem(String stableId, BuildContext itemContext) {
    if (identical(_mountedItemContexts[stableId], itemContext)) {
      _mountedItemContexts.remove(stableId);
    }
  }

  (ReaderBoundaryStatus, ReaderBoundaryStatus) _initialBoundaryStatuses() {
    final dataSource = widget.chapterDataSource;
    if (dataSource == null || dataSource.catalog.isEmpty) {
      return (
        ReaderBoundaryStatus.endOfCatalog,
        ReaderBoundaryStatus.endOfCatalog,
      );
    }
    final loadedIds = _loadedChapters.map((chapter) => chapter.id).toSet();
    final firstLoaded = dataSource.catalog.indexWhere(
      (chapter) => loadedIds.contains(chapter.id),
    );
    final lastLoaded = dataSource.catalog.lastIndexWhere(
      (chapter) => loadedIds.contains(chapter.id),
    );
    if (firstLoaded == -1 || lastLoaded == -1) {
      return (
        ReaderBoundaryStatus.unavailable,
        ReaderBoundaryStatus.unavailable,
      );
    }
    return (
      firstLoaded == 0
          ? ReaderBoundaryStatus.endOfCatalog
          : ReaderBoundaryStatus.loadable,
      lastLoaded == dataSource.catalog.length - 1
          ? ReaderBoundaryStatus.endOfCatalog
          : ReaderBoundaryStatus.loadable,
    );
  }

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_anchorBlockId, 'anchor-block-id');
    registerForRestoration(_modeIndex, 'reading-mode');
    registerForRestoration(_sourceIndex, 'translation-source');
    registerForRestoration(_chineseFontSize, 'chinese-font-size');
    registerForRestoration(_japaneseFontSize, 'japanese-font-size');
    registerForRestoration(_lineHeight, 'line-height');
    registerForRestoration(_japaneseOpacity, 'japanese-opacity');
    registerForRestoration(_readingWidth, 'reading-width');

    _anchorBlockId.value ??= widget.initialPosition?.blockId;
    _settings = ReaderSettings(
      readingMode: ReadingMode.values[_modeIndex.value],
      translationSource: TranslationSource.values[_sourceIndex.value],
      chineseFontSize: _chineseFontSize.value,
      japaneseFontSize: _japaneseFontSize.value,
      lineHeight: _lineHeight.value,
      japaneseOpacity: _japaneseOpacity.value,
      readingWidth: _readingWidth.value,
    );
    _scheduleInitialRestore();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleChromeDismiss();
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _chromeDismissTimer?.cancel();
      if (!_restoring) _captureAnchor(updateUi: false);
    }
  }

  @override
  void dispose() {
    widget.chapterDataSource?.removeChapterUpdateListener(_onChapterUpdated);
    _windowGeneration += 1;
    _chromeDismissTimer?.cancel();
    if (!_restoring) {
      final position = _lastPosition;
      if (position != null) {
        (widget.onExitPosition ?? widget.onPositionChanged)?.call(position);
      }
    }
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _anchorBlockId.dispose();
    _modeIndex.dispose();
    _sourceIndex.dispose();
    _chineseFontSize.dispose();
    _japaneseFontSize.dispose();
    _lineHeight.dispose();
    _japaneseOpacity.dispose();
    _readingWidth.dispose();
    super.dispose();
  }

  ReadingPosition? _resolvedInitialPosition() {
    if (widget.initialPosition case final initial?) {
      for (final chapter in _loadedChapters) {
        if (chapter.id != initial.chapterId) continue;
        if (chapter.blocks.any((block) => block.id == initial.blockId)) {
          return initial;
        }
        if (chapter.blocks.firstOrNull case final firstBlock?) {
          return ReadingPosition(chapterId: chapter.id, blockId: firstBlock.id);
        }
      }
    }
    for (final chapter in _loadedChapters) {
      if (chapter.blocks.firstOrNull case final firstBlock?) {
        return ReadingPosition(chapterId: chapter.id, blockId: firstBlock.id);
      }
    }
    return null;
  }

  void _scheduleInitialRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final blockId = _anchorBlockId.value;
      String? stableId;
      if (blockId != null) {
        final blockStableId = 'block:$blockId';
        if (_itemIndices.containsKey(blockStableId)) {
          stableId = blockStableId;
        } else if (widget.initialPosition case final position?) {
          final chapterStableId = 'chapter:${position.chapterId}';
          if (_itemIndices.containsKey(chapterStableId)) {
            stableId = chapterStableId;
            final chapter = _loadedChapters
                .where((chapter) => chapter.id == position.chapterId)
                .firstOrNull;
            _anchorBlockId.value = chapter?.blocks.firstOrNull?.id;
          }
        }
      }
      if (stableId != null) {
        final restoreOffset =
            widget.initialPosition != null &&
                widget.initialPosition!.blockId == blockId
            ? widget.initialPosition!.intraBlockOffset
            : 0;
        await _jumpToStableId(stableId, intraBlockOffset: restoreOffset);
        if (!mounted) return;
        final itemIndex = _itemIndices[stableId];
        if (itemIndex != null) {
          final item = _items[itemIndex];
          _activeChapterId = item.chapter.id;
          final block = switch (item) {
            AlignedBlockItem(:final block) => block,
            ChapterBoundaryItem() => item.chapter.blocks.firstOrNull,
          };
          if (block != null) {
            _lastPosition = ReadingPosition(
              chapterId: item.chapter.id,
              blockId: block.id,
              intraBlockOffset: restoreOffset,
            );
          }
        }
      }
      if (mounted) {
        setState(() => _restoring = false);
        _scheduleChromeDismiss();
      }
    });
  }

  Future<void> _jumpToStableId(
    String stableId, {
    int intraBlockOffset = 0,
  }) async {
    if (!mounted) return;
    final targetIndex = _itemIndices[stableId];
    if (targetIndex == null || !_scrollController.hasClients) return;

    var targetContext = _mountedContextFor(stableId);
    if (targetContext == null) {
      setState(() {
        _windowStart = (targetIndex - _jumpLeadInItems).clamp(0, _items.length);
        _windowEnd = (targetIndex + _initialWindowItems).clamp(
          _windowStart,
          _items.length,
        );
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      targetContext = _mountedContextFor(stableId);
    }
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0,
        duration: Duration.zero,
      );
      if (intraBlockOffset > 0 &&
          _scrollController.hasClients &&
          targetContext.mounted) {
        final box = targetContext.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          final extra = box.size.height * intraBlockOffset / 1000.0;
          final position = _scrollController.position;
          _scrollController.jumpTo(
            (position.pixels + extra).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
      }
    }
  }

  void _extendWindowForward() {
    if (_adjustingWindow || _windowEnd >= _items.length) return;
    _adjustingWindow = true;
    setState(() {
      _windowEnd = (_windowEnd + _windowExpansionItems).clamp(
        _windowStart,
        _items.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _adjustingWindow = false;
    });
  }

  void _extendWindowBackward() {
    if (_adjustingWindow ||
        _windowStart == 0 ||
        !_scrollController.hasClients) {
      return;
    }
    _adjustingWindow = true;
    final oldMaxExtent = _scrollController.position.maxScrollExtent;
    final oldPixels = _scrollController.position.pixels;
    setState(() {
      _windowStart = (_windowStart - _windowExpansionItems).clamp(
        0,
        _windowEnd,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final addedExtent =
          _scrollController.position.maxScrollExtent - oldMaxExtent;
      final target = (oldPixels + addedExtent).clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
      _adjustingWindow = false;
    });
  }

  void _handleScrollMetrics(ScrollMetrics metrics) {
    if (_restoring || _preservingDynamicAnchor) return;

    if (metrics.extentBefore > _boundaryRearmExtent) {
      _beforeRequestArmed = true;
    }
    if (metrics.extentAfter > _boundaryRearmExtent) {
      _afterRequestArmed = true;
    }

    if (metrics.extentBefore < _boundaryTriggerExtent) {
      if (_windowStart > 0) {
        _extendWindowBackward();
      } else if (_beforeRequestArmed) {
        _beforeRequestArmed = false;
        unawaited(_requestAdjacent(ReaderLoadDirection.before));
      }
    }
    if (metrics.extentAfter < _boundaryTriggerExtent) {
      if (_windowEnd < _items.length) {
        _extendWindowForward();
      } else if (_afterRequestArmed) {
        _afterRequestArmed = false;
        unawaited(_requestAdjacent(ReaderLoadDirection.after));
      }
    }
  }

  Future<void> _requestAdjacent(ReaderLoadDirection direction) async {
    final dataSource = widget.chapterDataSource;
    if (dataSource == null || _loadedChapters.isEmpty) return;
    final isBefore = direction == ReaderLoadDirection.before;
    if (isBefore ? _beforeLoading : _afterLoading) return;
    final status = isBefore ? _beforeBoundary : _afterBoundary;
    if (status != ReaderBoundaryStatus.loadable) return;

    final anchorChapter = isBefore
        ? _loadedChapters.first
        : _loadedChapters.last;
    final requestGeneration = _windowGeneration;
    setState(() {
      if (isBefore) {
        _beforeLoading = true;
        _beforeLoadError = null;
      } else {
        _afterLoading = true;
        _afterLoadError = null;
      }
    });

    try {
      final window = await dataSource.loadAdjacent(
        ReaderAdjacentRequest(
          anchorChapterId: anchorChapter.id,
          direction: direction,
        ),
      );
      if (!mounted || requestGeneration != _windowGeneration) return;
      final incoming = _validatedWindowChapters(
        window,
        adjacentTo: anchorChapter.id,
        direction: direction,
      );
      final loadedIds = _loadedChapters.map((chapter) => chapter.id).toSet();
      final hasNewChapter = incoming.any(
        (chapter) => !loadedIds.contains(chapter.id),
      );
      final resultingStatus = isBefore ? window.before : window.after;
      if (!hasNewChapter && resultingStatus == ReaderBoundaryStatus.loadable) {
        throw StateError('相邻章节服务未返回新内容。');
      }

      if (isBefore) {
        await _applyPrependedWindow(
          incoming,
          beforeStatus: window.before,
          // Capture at completion time: the reader may keep scrolling while
          // the adjacent request is in flight.
          visibleAnchor: _captureVisibleAnchor(),
        );
      } else {
        _applyAppendedWindow(incoming, afterStatus: window.after);
      }
    } catch (error) {
      if (!mounted || requestGeneration != _windowGeneration) return;
      setState(() {
        if (isBefore) {
          _beforeLoading = false;
          _beforeLoadError = error;
        } else {
          _afterLoading = false;
          _afterLoadError = error;
        }
      });
    }
  }

  List<NovelChapter> _validatedWindowChapters(
    ReaderChapterWindow window, {
    String? adjacentTo,
    ReaderLoadDirection? direction,
    String? requiredChapterId,
  }) {
    final catalog = _chapterCatalog;
    final catalogOrder = {
      for (var index = 0; index < catalog.length; index++)
        catalog[index].id: index,
    };
    final seen = <String>{};
    for (final chapter in window.chapters) {
      if (!seen.add(chapter.id)) {
        throw StateError('章节窗口包含重复章节：${chapter.id}');
      }
      if (!catalogOrder.containsKey(chapter.id)) {
        throw StateError('章节窗口包含目录外章节：${chapter.id}');
      }
    }
    if (requiredChapterId != null &&
        !window.chapters.any(
          (chapter) =>
              chapter.id == requiredChapterId && chapter.blocks.isNotEmpty,
        )) {
      throw StateError('章节窗口未包含所选章节正文。');
    }
    if (adjacentTo != null && direction != null) {
      final anchorOrder = catalogOrder[adjacentTo];
      if (anchorOrder == null) {
        throw StateError('当前章节不在完整目录中。');
      }
      final existingIds = _loadedChapters.map((chapter) => chapter.id).toSet();
      final newOrders = <int>[];
      for (final chapter in window.chapters) {
        if (existingIds.contains(chapter.id)) continue;
        final chapterOrder = catalogOrder[chapter.id]!;
        newOrders.add(chapterOrder);
        final isOnRequestedSide = direction == ReaderLoadDirection.before
            ? chapterOrder < anchorOrder
            : chapterOrder > anchorOrder;
        if (!isOnRequestedSide) {
          throw StateError('相邻章节服务返回了错误方向的章节。');
        }
      }
      if (newOrders.isNotEmpty) {
        newOrders.sort();
        final expectedAdjacent = direction == ReaderLoadDirection.before
            ? anchorOrder - 1
            : anchorOrder + 1;
        if (!newOrders.contains(expectedAdjacent)) {
          throw StateError('相邻章节窗口跳过了紧邻章节。');
        }
        for (var index = 1; index < newOrders.length; index++) {
          if (newOrders[index] != newOrders[index - 1] + 1) {
            throw StateError('相邻章节窗口不连续。');
          }
        }
      }
    }
    return List.of(window.chapters);
  }

  void _mergeLoadedChapters(List<NovelChapter> incoming) {
    final byId = {
      for (final chapter in _loadedChapters) chapter.id: chapter,
      for (final chapter in incoming) chapter.id: chapter,
    };
    _loadedChapters = byId.values.toList();
    _rebuildStream();
  }

  void _applyAppendedWindow(
    List<NovelChapter> incoming, {
    required ReaderBoundaryStatus afterStatus,
  }) {
    final oldItemCount = _items.length;
    final oldWindowEnd = _windowEnd;
    setState(() {
      _mergeLoadedChapters(incoming);
      final addedItems = (_items.length - oldItemCount).clamp(0, _items.length);
      _windowEnd = (oldWindowEnd + addedItems).clamp(
        _windowStart,
        _items.length,
      );
      _afterBoundary = afterStatus;
      _afterLoading = false;
      _afterLoadError = null;
      _afterRequestArmed = afterStatus == ReaderBoundaryStatus.loadable;
    });
  }

  Future<void> _applyPrependedWindow(
    List<NovelChapter> incoming, {
    required ReaderBoundaryStatus beforeStatus,
    required _VisibleReaderAnchor? visibleAnchor,
  }) async {
    final oldWindowSpan = (_windowEnd - _windowStart).clamp(
      1,
      _initialWindowItems,
    );
    int? renderedAnchorIndex;
    setState(() {
      _preservingDynamicAnchor = true;
      _mergeLoadedChapters(incoming);
      final anchorIndex = visibleAnchor == null
          ? null
          : _itemIndices[visibleAnchor.stableId];
      if (anchorIndex != null) {
        renderedAnchorIndex = anchorIndex;
        // Reveal the prepended lead-in on a second frame so scroll
        // compensation uses the exact added extent.
        _windowStart = anchorIndex;
        _windowEnd = (anchorIndex + oldWindowSpan).clamp(
          _windowStart,
          _items.length,
        );
      } else {
        _windowStart = 0;
        _windowEnd = oldWindowSpan.clamp(0, _items.length);
      }
      _beforeBoundary = beforeStatus;
      _beforeLoading = false;
      _beforeLoadError = null;
      _beforeRequestArmed = beforeStatus == ReaderBoundaryStatus.loadable;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (renderedAnchorIndex != null && _scrollController.hasClients) {
      final oldMaxExtent = _scrollController.position.maxScrollExtent;
      final oldPixels = _scrollController.position.pixels;
      setState(() {
        _windowStart = (renderedAnchorIndex! - _windowLeadInItems).clamp(
          0,
          _windowEnd,
        );
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scrollController.hasClients) return;
      final addedExtent =
          _scrollController.position.maxScrollExtent - oldMaxExtent;
      final position = _scrollController.position;
      _scrollController.jumpTo(
        (oldPixels + addedExtent).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scrollController.hasClients) return;
    }
    if (visibleAnchor != null && _scrollController.hasClients) {
      var itemContext = _mountedContextFor(visibleAnchor.stableId);
      if (itemContext == null) {
        await _jumpToStableId(visibleAnchor.stableId);
        if (!mounted || !_scrollController.hasClients) return;
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !_scrollController.hasClients) return;
        itemContext = _mountedContextFor(visibleAnchor.stableId);
      }
      if (itemContext != null && itemContext.mounted) {
        await Scrollable.ensureVisible(
          itemContext,
          alignment: 0,
          duration: Duration.zero,
        );
        if (!mounted || !_scrollController.hasClients) return;
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !_scrollController.hasClients) return;
      }
      final viewportContext = _viewportKey.currentContext;
      final itemBox = itemContext?.findRenderObject();
      final viewportBox = viewportContext?.findRenderObject();
      if (itemBox is RenderBox &&
          itemBox.hasSize &&
          viewportBox is RenderBox &&
          viewportBox.hasSize) {
        final newOffset =
            itemBox.localToGlobal(Offset.zero).dy -
            viewportBox.localToGlobal(Offset.zero).dy;
        final correction = newOffset - visibleAnchor.viewportOffset;
        final position = _scrollController.position;
        _scrollController.jumpTo(
          (position.pixels + correction).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      }
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(() => _preservingDynamicAnchor = false);
  }

  _VisibleReaderAnchor? _captureVisibleAnchor() {
    final anchor = _captureAnchor(notify: false, updateUi: false);
    final viewportContext = _viewportKey.currentContext;
    final itemContext = anchor == null
        ? null
        : _mountedContextFor(anchor.stableId);
    final viewportBox = viewportContext?.findRenderObject();
    final itemBox = itemContext?.findRenderObject();
    if (anchor == null ||
        viewportBox is! RenderBox ||
        !viewportBox.hasSize ||
        itemBox is! RenderBox ||
        !itemBox.hasSize) {
      return null;
    }
    return _VisibleReaderAnchor(
      stableId: anchor.stableId,
      viewportOffset:
          itemBox.localToGlobal(Offset.zero).dy -
          viewportBox.localToGlobal(Offset.zero).dy,
    );
  }

  AlignedBlockItem? _captureAnchor({bool notify = true, bool updateUi = true}) {
    final viewportContext = _viewportKey.currentContext;
    if (viewportContext == null) return null;
    final viewportBox = viewportContext.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;

    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    AlignedBlockItem? firstSubstantiallyVisible;
    AlignedBlockItem? nearestVisible;
    var nearestTop = double.infinity;

    final mountedItems = <(int, AlignedBlockItem)>[];
    for (final blockId in _mountedBlockIds) {
      final index = _itemIndices['block:$blockId'];
      if (index == null) continue;
      final item = _items[index];
      if (item is AlignedBlockItem) mountedItems.add((index, item));
    }
    mountedItems.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, item) in mountedItems) {
      final itemContext = _mountedContextFor(item.stableId);
      final renderObject = itemContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;
      final top = renderObject.localToGlobal(Offset.zero).dy;
      final bottom = top + renderObject.size.height;
      final visibleHeight =
          (bottom.clamp(viewportTop, viewportBottom) -
                  top.clamp(viewportTop, viewportBottom))
              .clamp(0.0, renderObject.size.height);
      if (visibleHeight <= 0) continue;

      final distanceFromTop = (top - viewportTop).abs();
      if (distanceFromTop < nearestTop) {
        nearestTop = distanceFromTop;
        nearestVisible = item;
      }
      if (firstSubstantiallyVisible == null &&
          visibleHeight >= renderObject.size.height * 0.35) {
        firstSubstantiallyVisible = item;
      }
    }

    final anchor = firstSubstantiallyVisible ?? nearestVisible;
    if (anchor == null) return null;
    var intraBlockOffset = 0;
    final anchorContext = _mountedContextFor(anchor.stableId);
    final anchorBox = anchorContext?.findRenderObject();
    if (anchorBox is RenderBox &&
        anchorBox.hasSize &&
        anchorBox.size.height > 0) {
      final top = anchorBox.localToGlobal(Offset.zero).dy;
      final pixelsIntoBlock = (viewportTop - top).clamp(
        0.0,
        anchorBox.size.height,
      );
      intraBlockOffset = (pixelsIntoBlock / anchorBox.size.height * 1000)
          .round()
          .clamp(0, 1000);
    }
    final position = ReadingPosition(
      chapterId: anchor.chapter.id,
      blockId: anchor.block.id,
      intraBlockOffset: intraBlockOffset,
    );
    final changed = _lastPosition != position;
    _anchorBlockId.value = anchor.block.id;
    _lastPosition = position;
    final chapterChanged = _activeChapterId != anchor.chapter.id;
    _activeChapterId = anchor.chapter.id;
    if (chapterChanged && updateUi && mounted) {
      setState(() {});
    }
    if (notify && changed) {
      widget.onPositionChanged?.call(_lastPosition!);
    }
    return anchor;
  }

  Future<void> _applySettings(
    ReaderSettings settings, {
    ThemeMode? themeMode,
  }) async {
    final anchor = _captureAnchor();
    setState(() {
      _settings = settings;
      _restoring = true;
      _modeIndex.value = settings.readingMode.index;
      _sourceIndex.value = settings.translationSource.index;
      _chineseFontSize.value = settings.chineseFontSize;
      _japaneseFontSize.value = settings.japaneseFontSize;
      _lineHeight.value = settings.lineHeight;
      _japaneseOpacity.value = settings.japaneseOpacity;
      _readingWidth.value = settings.readingWidth;
    });
    if (themeMode != null && themeMode != widget.themeMode) {
      widget.onThemeModeChanged(themeMode);
    }
    widget.onSettingsChanged?.call(settings);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (anchor != null) {
      await _jumpToStableId(anchor.stableId);
      if (!mounted) return;
    }
    setState(() => _restoring = false);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_tapPointer != null) return;
    _tapPointer = event.pointer;
    _tapOrigin = event.position;
    _tapStartedAt = DateTime.now();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _tapPointer) {
      _clearTapCandidate();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _tapPointer ||
        _tapOrigin == null ||
        _tapStartedAt == null) {
      return;
    }
    final travel = (event.position - _tapOrigin!).distance;
    final elapsed = DateTime.now().difference(_tapStartedAt!);
    final isTap = travel < 12 && elapsed < const Duration(milliseconds: 450);
    _clearTapCandidate();
    if (isTap) {
      _handleReadingTap(event.position);
    }
  }

  void _clearTapCandidate() {
    _tapPointer = null;
    _tapOrigin = null;
    _tapStartedAt = null;
  }

  void _handleReadingTap(Offset point) {
    if (_chromeVisible) {
      _hideChrome();
      return;
    }
    final size = MediaQuery.sizeOf(context);
    final inHorizontalCenter =
        point.dx >= size.width * 0.25 && point.dx <= size.width * 0.75;
    final inVerticalCenter =
        point.dy >= size.height * 0.30 && point.dy <= size.height * 0.70;
    if (inHorizontalCenter && inVerticalCenter) {
      _showChrome();
    }
  }

  void _showChrome() {
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
    _scheduleChromeDismiss();
  }

  void _hideChrome() {
    _chromeDismissTimer?.cancel();
    if (_chromeVisible && mounted) {
      setState(() => _chromeVisible = false);
    }
  }

  void _scheduleChromeDismiss() {
    _chromeDismissTimer?.cancel();
    if (!mounted || !_chromeVisible || _restoring) return;
    _chromeDismissTimer = Timer(_chromeAutoHideDelay, _hideChrome);
  }

  void _handleReaderScroll(ScrollNotification notification) {
    final userScrollStarted =
        notification is ScrollStartNotification &&
            notification.dragDetails != null ||
        notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle;
    if (userScrollStarted) _hideChrome();
  }

  void _runChromeAction(VoidCallback action) {
    _scheduleChromeDismiss();
    action();
  }

  Future<void> _showCatalog() async {
    final chapter = await showModalBottomSheet<ReaderChapterCatalogEntry>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ChapterCatalogSheet(
        catalog: _chapterCatalog,
        activeChapterId: _activeChapterId,
        loadedChapterIds: _loadedChapters
            .where((chapter) => chapter.blocks.isNotEmpty)
            .map((chapter) => chapter.id)
            .toSet(),
      ),
    );
    if (chapter == null || !mounted) return;
    await _openCatalogEntry(chapter);
  }

  Future<void> _openCatalogEntry(ReaderChapterCatalogEntry entry) async {
    if (_catalogLoading) return;
    final loadedChapter = _loadedChapters
        .where((chapter) => chapter.id == entry.id && chapter.blocks.isNotEmpty)
        .firstOrNull;
    if (loadedChapter != null) {
      await _jumpToLoadedChapter(loadedChapter);
      return;
    }
    final dataSource = widget.chapterDataSource;
    if (dataSource == null) {
      setState(() {
        _catalogLoading = false;
        _catalogRetryEntry = entry;
        _catalogLoadError = StateError('该章节正文当前不可用。');
      });
      return;
    }
    final requestGeneration = ++_windowGeneration;
    setState(() {
      _beforeLoading = false;
      _afterLoading = false;
      _beforeLoadError = null;
      _afterLoadError = null;
      _catalogLoading = true;
      _catalogLoadError = null;
      _catalogRetryEntry = entry;
    });
    try {
      final window = await dataSource.loadAround(entry.id);
      if (!mounted || requestGeneration != _windowGeneration) return;
      final chapters = _validatedWindowChapters(
        window,
        requiredChapterId: entry.id,
      );
      setState(() {
        _loadedChapters = chapters;
        _rebuildStream();
        final targetIndex = _itemIndices['chapter:${entry.id}'] ?? 0;
        _windowStart = (targetIndex - _jumpLeadInItems).clamp(0, _items.length);
        _windowEnd = (targetIndex + _initialWindowItems).clamp(
          _windowStart,
          _items.length,
        );
        _beforeBoundary = window.before;
        _afterBoundary = window.after;
        _beforeLoadError = null;
        _afterLoadError = null;
        _beforeLoading = false;
        _afterLoading = false;
        _beforeRequestArmed = true;
        _afterRequestArmed = true;
        _catalogLoading = false;
        _catalogLoadError = null;
        _catalogRetryEntry = null;
      });
      final selected = _loadedChapters
          .where((chapter) => chapter.id == entry.id)
          .first;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await _jumpToLoadedChapter(selected);
    } catch (error) {
      if (!mounted || requestGeneration != _windowGeneration) return;
      setState(() {
        _catalogLoading = false;
        _catalogLoadError = error;
        _catalogRetryEntry = entry;
      });
    }
  }

  Future<void> _jumpToLoadedChapter(NovelChapter chapter) async {
    setState(() => _restoring = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _jumpToStableId('chapter:${chapter.id}');
    if (!mounted) return;
    final firstBlock = chapter.blocks.isEmpty ? null : chapter.blocks.first;
    if (firstBlock != null) {
      _anchorBlockId.value = firstBlock.id;
      _activeChapterId = chapter.id;
      _lastPosition = ReadingPosition(
        chapterId: chapter.id,
        blockId: firstBlock.id,
      );
      widget.onPositionChanged?.call(_lastPosition!);
    }
    setState(() {
      _activeChapterId = chapter.id;
      _restoring = false;
    });
  }

  void _dismissCatalogError() {
    setState(() {
      _catalogLoadError = null;
      _catalogRetryEntry = null;
    });
  }

  Future<void> _showTranslationSources() async {
    final source = await showModalBottomSheet<TranslationSource>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) =>
          _TranslationSourceSheet(selectedSource: _settings.translationSource),
    );
    if (source != null && source != _settings.translationSource && mounted) {
      await _applySettings(_settings.copyWith(translationSource: source));
    }
  }

  Future<void> _showSettings() async {
    final result = await showModalBottomSheet<_SettingsResult>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ReaderSettingsSheet(
        settings: _settings,
        themeMode: widget.themeMode,
      ),
    );
    if (result != null && mounted) {
      await _applySettings(result.settings, themeMode: result.themeMode);
    }
  }

  void _toggleMode() {
    final nextMode = _settings.readingMode == ReadingMode.chineseJapanese
        ? ReadingMode.chineseOnly
        : ReadingMode.chineseJapanese;
    unawaited(_applySettings(_settings.copyWith(readingMode: nextMode)));
  }

  void _toggleBookmark() {
    final anchor = _captureAnchor();
    if (anchor == null) return;
    final position = ReadingPosition(
      chapterId: anchor.chapter.id,
      blockId: anchor.block.id,
    );
    final bookmarked = !_bookmarks.contains(anchor.block.id);
    setState(() {
      if (bookmarked) {
        _bookmarks.add(anchor.block.id);
      } else {
        _bookmarks.remove(anchor.block.id);
      }
    });
    widget.onBookmarkChanged?.call(position, bookmarked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final readerBackground = isDark
        ? const Color(0xFF171A18)
        : const Color(0xFFF5F2E8);
    final foreground = isDark
        ? const Color(0xFFE8ECE8)
        : const Color(0xFF252925);
    NovelChapter? currentChapter;
    for (final chapter in _loadedChapters) {
      if (chapter.id == _activeChapterId) {
        currentChapter = chapter;
        break;
      }
    }
    if (currentChapter == null && _loadedChapters.isNotEmpty) {
      currentChapter = _loadedChapters.first;
    }
    final currentBookmark =
        _anchorBlockId.value != null &&
        _bookmarks.contains(_anchorBlockId.value);

    return Scaffold(
      backgroundColor: readerBackground,
      body: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              key: const ValueKey('reader-center-tap-area'),
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handlePointerDown,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  _handleScrollMetrics(notification.metrics);
                  _handleReaderScroll(notification);
                  if (!_restoring &&
                      !_preservingDynamicAnchor &&
                      (notification is ScrollEndNotification ||
                          notification is ScrollUpdateNotification)) {
                    _captureAnchor(
                      notify: notification is ScrollEndNotification,
                    );
                  }
                  return false;
                },
                child: KeyedSubtree(
                  key: const ValueKey('reader-stream'),
                  child: SizedBox.expand(
                    key: _viewportKey,
                    child: RepaintBoundary(
                      key: const ValueKey('reader-scroll-repaint-boundary'),
                      child: ListView.builder(
                        controller: _scrollController,
                        physics: const ClampingScrollPhysics(),
                        scrollCacheExtent: const ScrollCacheExtent.viewport(2),
                        addAutomaticKeepAlives: false,
                        addSemanticIndexes: false,
                        padding: EdgeInsets.only(
                          top: MediaQuery.paddingOf(context).top + 88,
                          bottom: MediaQuery.paddingOf(context).bottom + 112,
                        ),
                        itemCount:
                            _windowEnd -
                            _windowStart +
                            (_windowStart == 0 ? 1 : 0) +
                            (_windowEnd == _items.length ? 1 : 0),
                        itemBuilder: (context, index) {
                          final showBeforeBoundary = _windowStart == 0;
                          final streamLength = _windowEnd - _windowStart;
                          if (showBeforeBoundary && index == 0) {
                            return _ReaderAvailabilityBoundary(
                              direction: ReaderLoadDirection.before,
                              status: _beforeBoundary,
                              loading: _beforeLoading,
                              error: _beforeLoadError,
                              onRetry: () => unawaited(
                                _requestAdjacent(ReaderLoadDirection.before),
                              ),
                            );
                          }
                          final streamIndex =
                              index - (showBeforeBoundary ? 1 : 0);
                          if (streamIndex >= streamLength) {
                            return _ReaderAvailabilityBoundary(
                              direction: ReaderLoadDirection.after,
                              status: _afterBoundary,
                              loading: _afterLoading,
                              error: _afterLoadError,
                              onRetry: () => unawaited(
                                _requestAdjacent(ReaderLoadDirection.after),
                              ),
                            );
                          }
                          final item = _items[_windowStart + streamIndex];
                          return switch (item) {
                            ChapterBoundaryItem() => _ChapterBoundary(
                              item: item,
                              itemKey: _itemKeys[item.stableId]!,
                              settings: _settings,
                              foreground: foreground,
                            ),
                            AlignedBlockItem() => _AlignedBlockView(
                              key: ValueKey(item.stableId),
                              item: item,
                              settings: _settings,
                              foreground: foreground,
                              onMounted: (itemContext) {
                                _mountedBlockIds.add(item.block.id);
                                _registerMountedItem(
                                  item.stableId,
                                  itemContext,
                                );
                              },
                              onUnmounted: (itemContext) {
                                _mountedBlockIds.remove(item.block.id);
                                _unregisterMountedItem(
                                  item.stableId,
                                  itemContext,
                                );
                              },
                            ),
                          };
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          _ReaderTopChrome(
            visible: _chromeVisible,
            title: widget.novel.chineseTitle,
            chapterTitle: currentChapter?.chineseTitle ?? '',
            onBack: () => Navigator.maybePop(context),
          ),
          _ReaderBottomChrome(
            visible: _chromeVisible,
            mode: _settings.readingMode,
            source: _settings.translationSource,
            bookmarked: currentBookmark,
            onCatalog: () => _runChromeAction(_showCatalog),
            onMode: () => _runChromeAction(_toggleMode),
            onSource: () => _runChromeAction(_showTranslationSources),
            onSettings: () => _runChromeAction(_showSettings),
            onBookmark: () => _runChromeAction(_toggleBookmark),
          ),
          if (_catalogLoading || _catalogLoadError != null)
            _ReaderCatalogLoadOverlay(
              loading: _catalogLoading,
              error: _catalogLoadError,
              chapter: _catalogRetryEntry,
              onDismiss: _dismissCatalogError,
              onRetry: _catalogRetryEntry == null
                  ? null
                  : () => unawaited(_openCatalogEntry(_catalogRetryEntry!)),
            ),
          if (_restoring)
            Positioned.fill(
              child: ColoredBox(
                key: const ValueKey('reader-restoring'),
                color: readerBackground,
                child: const _ReaderSkeleton(),
              ),
            ),
        ],
      ),
    );
  }
}

class _VisibleReaderAnchor {
  const _VisibleReaderAnchor({
    required this.stableId,
    required this.viewportOffset,
  });

  final String stableId;
  final double viewportOffset;
}

class _ReaderAvailabilityBoundary extends StatelessWidget {
  const _ReaderAvailabilityBoundary({
    required this.direction,
    required this.status,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final ReaderLoadDirection direction;
  final ReaderBoundaryStatus status;
  final bool loading;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final side = direction.name;
    if (loading) {
      return Semantics(
        key: ValueKey('reader-load-$side-loading'),
        container: true,
        liveRegion: true,
        label: direction == ReaderLoadDirection.before
            ? '正在加载较早章节'
            : '正在加载后续章节',
        child: const _ReaderBoundaryFrame(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('正在加载相邻章节…'),
            ],
          ),
        ),
      );
    }
    if (error != null) {
      return Semantics(
        key: ValueKey('reader-load-$side-error'),
        container: true,
        liveRegion: true,
        label: '相邻章节加载失败，可重试',
        child: _ReaderBoundaryFrame(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 18),
              const SizedBox(width: 8),
              const Flexible(child: Text('相邻章节加载失败')),
              const SizedBox(width: 6),
              TextButton(
                key: ValueKey('retry-reader-load-$side'),
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final (icon, message) = switch ((direction, status)) {
      (ReaderLoadDirection.before, ReaderBoundaryStatus.endOfCatalog) => (
        Icons.first_page_rounded,
        '已到作品开头',
      ),
      (ReaderLoadDirection.after, ReaderBoundaryStatus.endOfCatalog) => (
        Icons.check_circle_outline_rounded,
        '已读到最新章节',
      ),
      (ReaderLoadDirection.before, ReaderBoundaryStatus.unavailable) => (
        Icons.cloud_off_outlined,
        '较早章节当前不可用',
      ),
      (ReaderLoadDirection.after, ReaderBoundaryStatus.unavailable) => (
        Icons.cloud_off_outlined,
        '后续章节当前不可用',
      ),
      (ReaderLoadDirection.before, ReaderBoundaryStatus.loadable) => (
        Icons.expand_less_rounded,
        '继续向上即可加载较早章节',
      ),
      (ReaderLoadDirection.after, ReaderBoundaryStatus.loadable) => (
        Icons.expand_more_rounded,
        '继续向下即可加载后续章节',
      ),
    };
    return Semantics(
      key: ValueKey('reader-boundary-$side-${status.name}'),
      container: true,
      label: message,
      child: _ReaderBoundaryFrame(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
      ),
    );
  }
}

class _ReaderBoundaryFrame extends StatelessWidget {
  const _ReaderBoundaryFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 72),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 13,
          ),
          child: IconTheme.merge(
            data: IconThemeData(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _ReaderCatalogLoadOverlay extends StatelessWidget {
  const _ReaderCatalogLoadOverlay({
    required this.loading,
    required this.error,
    required this.chapter,
    required this.onDismiss,
    required this.onRetry,
  });

  final bool loading;
  final Object? error;
  final ReaderChapterCatalogEntry? chapter;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final chapterId = chapter?.id ?? 'unknown';
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.32),
        child: Center(
          child: Semantics(
            key: ValueKey(
              loading
                  ? 'reader-catalog-loading-$chapterId'
                  : 'reader-catalog-error-$chapterId',
            ),
            container: true,
            liveRegion: true,
            label: loading
                ? '正在加载${chapter?.chineseTitle ?? '所选章节'}'
                : '所选章节加载失败',
            child: Card(
              margin: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: loading
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 14),
                            Text('正在加载章节正文…'),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.cloud_off_rounded, size: 32),
                            const SizedBox(height: 12),
                            Text(
                              '暂时无法打开「${chapter?.chineseTitle ?? '所选章节'}」',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: onDismiss,
                                  child: const Text('关闭'),
                                ),
                                if (onRetry != null) ...[
                                  const SizedBox(width: 8),
                                  FilledButton(
                                    key: ValueKey(
                                      'retry-reader-catalog-$chapterId',
                                    ),
                                    onPressed: onRetry,
                                    child: const Text('重试'),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChapterBoundary extends StatelessWidget {
  const _ChapterBoundary({
    required this.item,
    required this.itemKey,
    required this.settings,
    required this.foreground,
  });

  final ChapterBoundaryItem item;
  final GlobalKey itemKey;
  final ReaderSettings settings;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final chapter = item.chapter;
    final state = chapter.translationState(settings.translationSource);
    final published = chapter.publishedAt;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: settings.readingWidth),
        child: Semantics(
          key: itemKey,
          header: true,
          container: true,
          label:
              '第${chapter.index}章，${chapter.chineseTitle}，${chapter.japaneseTitle}',
          child: Padding(
            key: ValueKey('chapter-boundary-${chapter.id}'),
            padding: const EdgeInsets.fromLTRB(24, 42, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '第 ${chapter.index} 章',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (published != null)
                      Text(
                        '${published.year}.${published.month.toString().padLeft(2, '0')}.${published.day.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          color: foreground.withValues(alpha: 0.52),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  chapter.chineseTitle,
                  locale: const Locale('zh', 'CN'),
                  style: TextStyle(
                    color: foreground,
                    fontSize: 27,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  chapter.japaneseTitle,
                  locale: const Locale('ja', 'JP'),
                  style: TextStyle(
                    color: foreground.withValues(alpha: 0.55),
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                Divider(color: foreground.withValues(alpha: 0.15)),
                if (state != TranslationState.complete) ...[
                  const SizedBox(height: 16),
                  _TranslationNotice(
                    key: ValueKey('translation-state-${chapter.id}'),
                    state: state,
                    source: settings.translationSource,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TranslationNotice extends StatelessWidget {
  const _TranslationNotice({
    required this.state,
    required this.source,
    super.key,
  });

  final TranslationState state;
  final TranslationSource source;

  @override
  Widget build(BuildContext context) {
    final invalid = state == TranslationState.invalid;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: invalid
            ? Theme.of(context).colorScheme.errorContainer
            : Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(invalid ? Icons.warning_amber_rounded : Icons.schedule_rounded),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              invalid
                  ? '${source.label} 译文结构异常，已完整显示日文原文。'
                  : '${source.label} 译文尚未生成，现显示完整日文原文；联网后会自动复查。',
              style: const TextStyle(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlignedBlockView extends StatefulWidget {
  const _AlignedBlockView({
    required this.item,
    required this.settings,
    required this.foreground,
    required this.onMounted,
    required this.onUnmounted,
    super.key,
  });

  final AlignedBlockItem item;
  final ReaderSettings settings;
  final Color foreground;
  final ValueChanged<BuildContext> onMounted;
  final ValueChanged<BuildContext> onUnmounted;

  @override
  State<_AlignedBlockView> createState() => _AlignedBlockViewState();
}

class _AlignedBlockViewState extends State<_AlignedBlockView> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onMounted(context);
  }

  @override
  void didUpdateWidget(_AlignedBlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.block.id == widget.item.block.id) return;
    oldWidget.onUnmounted(context);
    widget.onMounted(context);
  }

  @override
  void dispose() {
    widget.onUnmounted(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.item.block.kind == AlignedBlockKind.illustration) {
      return _IllustrationBlockView(
        block: widget.item.block,
        readingWidth: widget.settings.readingWidth,
        foreground: widget.foreground,
      );
    }
    final translationState = widget.item.chapter.translationState(
      widget.settings.translationSource,
    );
    final translation = translationState == TranslationState.complete
        ? widget.item.block.translationFor(widget.settings.translationSource)
        : null;
    final showJapanese =
        translation == null ||
        widget.settings.readingMode == ReadingMode.chineseJapanese;
    final isDialogue = widget.item.block.kind == AlignedBlockKind.dialogue;
    final semanticLabel = [
      if (translation != null) '中文：$translation',
      if (showJapanese) '日文：${widget.item.block.japanese}',
    ].join('\n');

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.settings.readingWidth),
        child: Semantics(
          container: true,
          excludeSemantics: true,
          label: semanticLabel,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              isDialogue ? 34 : 24,
              9,
              isDialogue ? 30 : 24,
              15,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (translation != null)
                  Text(
                    translation,
                    key: ValueKey('block-${widget.item.block.id}-chinese'),
                    style: TextStyle(
                      locale: const Locale('zh', 'CN'),
                      color: widget.foreground,
                      fontSize: widget.settings.chineseFontSize,
                      height: widget.settings.lineHeight,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0.15,
                    ),
                  ),
                if (translation != null && showJapanese)
                  SizedBox(height: widget.settings.chineseFontSize * 0.42),
                if (showJapanese)
                  Text(
                    widget.item.block.japanese,
                    key: ValueKey('block-${widget.item.block.id}-japanese'),
                    style: TextStyle(
                      locale: const Locale('ja', 'JP'),
                      color: widget.foreground.withValues(
                        alpha: translation == null
                            ? 0.88
                            : widget.settings.japaneseOpacity,
                      ),
                      fontSize: translation == null
                          ? widget.settings.chineseFontSize * 0.92
                          : widget.settings.japaneseFontSize,
                      height: widget.settings.lineHeight,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IllustrationBlockView extends StatefulWidget {
  const _IllustrationBlockView({
    required this.block,
    required this.readingWidth,
    required this.foreground,
  });

  final AlignedBlock block;
  final double readingWidth;
  final Color foreground;

  @override
  State<_IllustrationBlockView> createState() => _IllustrationBlockViewState();
}

class _IllustrationBlockViewState extends State<_IllustrationBlockView> {
  static final Map<String, double> _aspectByUrl = <String, double>{};
  static const _placeholderAspectRatio = 3 / 4;

  ImageStream? _stream;
  ImageStreamListener? _listener;

  AlignedBlock get _block => widget.block;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listenForSize();
  }

  @override
  void didUpdateWidget(_IllustrationBlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.illustrationUri != _block.illustrationUri) {
      _listenForSize();
    }
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  void _listenForSize() {
    _stopListening();
    final uri = _block.illustrationUri;
    if (uri == null) return;
    final key = uri.toString();
    if (_aspectByUrl.containsKey(key)) return;
    final provider = NetworkImage(
      key,
      headers: uri.host.endsWith('.pximg.net')
          ? const {'Referer': 'https://www.pixiv.net/'}
          : null,
    );
    final stream = provider.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener((info, _) {
      final height = info.image.height;
      if (height <= 0) return;
      _aspectByUrl[key] = info.image.width / height;
      if (mounted) setState(() {});
    }, onError: (_, _) {});
    _stream = stream;
    stream.addListener(_listener!);
  }

  void _stopListening() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _stream = null;
    _listener = null;
  }

  @override
  Widget build(BuildContext context) {
    final uri = _block.illustrationUri;
    final aspect = uri == null
        ? _placeholderAspectRatio
        : _aspectByUrl[uri.toString()] ?? _placeholderAspectRatio;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.readingWidth),
        child: Semantics(
          container: true,
          image: true,
          label: '小说插图',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: uri == null
                ? _IllustrationFailure(
                    blockId: _block.id,
                    foreground: widget.foreground,
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: AspectRatio(
                      aspectRatio: aspect,
                      child: Image.network(
                        uri.toString(),
                        key: ValueKey('block-${_block.id}-illustration'),
                        width: double.infinity,
                        fit: BoxFit.contain,
                        headers: uri.host.endsWith('.pximg.net')
                            ? const {'Referer': 'https://www.pixiv.net/'}
                            : null,
                        frameBuilder: (context, child, frame, synchronous) {
                          if (synchronous || frame != null) return child;
                          return const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) =>
                            _IllustrationFailure(
                              blockId: _block.id,
                              foreground: widget.foreground,
                            ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _IllustrationFailure extends StatelessWidget {
  const _IllustrationFailure({required this.blockId, required this.foreground});

  final String blockId;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('block-$blockId-illustration-failure'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      decoration: BoxDecoration(
        border: Border.all(color: foreground.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            color: foreground.withValues(alpha: 0.64),
          ),
          const SizedBox(height: 8),
          Text(
            '插图暂时无法加载',
            style: TextStyle(color: foreground.withValues(alpha: 0.72)),
          ),
        ],
      ),
    );
  }
}

class _ReaderTopChrome extends StatelessWidget {
  const _ReaderTopChrome({
    required this.visible,
    required this.title,
    required this.chapterTitle,
    required this.onBack,
  });

  final bool visible;
  final String title;
  final String chapterTitle;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          offset: visible ? Offset.zero : const Offset(0, -1),
          child: AnimatedOpacity(
            key: const ValueKey('reader-top-chrome'),
            duration: const Duration(milliseconds: 140),
            opacity: visible ? 1 : 0,
            child: Material(
              elevation: 1,
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.97),
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 64,
                  child: Row(
                    children: [
                      IconButton(
                        key: const ValueKey('reader-back-button'),
                        tooltip: '返回',
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              chapterTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderBottomChrome extends StatelessWidget {
  const _ReaderBottomChrome({
    required this.visible,
    required this.mode,
    required this.source,
    required this.bookmarked,
    required this.onCatalog,
    required this.onMode,
    required this.onSource,
    required this.onSettings,
    required this.onBookmark,
  });

  final bool visible;
  final ReadingMode mode;
  final TranslationSource source;
  final bool bookmarked;
  final VoidCallback onCatalog;
  final VoidCallback onMode;
  final VoidCallback onSource;
  final VoidCallback onSettings;
  final VoidCallback onBookmark;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          offset: visible ? Offset.zero : const Offset(0, 1),
          child: AnimatedOpacity(
            key: const ValueKey('reader-bottom-chrome'),
            duration: const Duration(milliseconds: 140),
            opacity: visible ? 1 : 0,
            child: Material(
              elevation: 4,
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.97),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: 76,
                  child: Row(
                    children: [
                      _ChromeAction(
                        key: const ValueKey('catalog-button'),
                        icon: Icons.format_list_numbered_rounded,
                        label: '目录',
                        onTap: onCatalog,
                      ),
                      _ChromeAction(
                        key: const ValueKey('reading-mode-button'),
                        icon: Icons.translate_rounded,
                        label: mode == ReadingMode.chineseJapanese
                            ? '中日'
                            : '中文',
                        onTap: onMode,
                      ),
                      _ChromeAction(
                        key: const ValueKey('translation-source-button'),
                        icon: Icons.hub_outlined,
                        label: source.label,
                        onTap: onSource,
                      ),
                      _ChromeAction(
                        key: const ValueKey('reader-settings-button'),
                        icon: Icons.text_fields_rounded,
                        label: '样式',
                        onTap: onSettings,
                      ),
                      _ChromeAction(
                        key: const ValueKey('bookmark-button'),
                        icon: bookmarked
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        label: bookmarked ? '已书签' : '书签',
                        onTap: onBookmark,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChromeAction extends StatelessWidget {
  const _ChromeAction({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 23),
              const SizedBox(height: 4),
              Text(label, maxLines: 1, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChapterCatalogSheet extends StatelessWidget {
  const _ChapterCatalogSheet({
    required this.catalog,
    required this.activeChapterId,
    required this.loadedChapterIds,
  });

  final List<ReaderChapterCatalogEntry> catalog;
  final String? activeChapterId;
  final Set<String> loadedChapterIds;

  List<({String? title, ReaderChapterCatalogEntry? chapter})> get _rows {
    final grouped = catalog.any(
      (entry) => entry.sectionTitle != null && entry.sectionTitle!.isNotEmpty,
    );
    if (!grouped) {
      return [for (final chapter in catalog) (title: null, chapter: chapter)];
    }
    final rows = <({String? title, ReaderChapterCatalogEntry? chapter})>[];
    String? current;
    for (final chapter in catalog) {
      final title =
          (chapter.sectionTitle == null || chapter.sectionTitle!.isEmpty)
          ? '章节'
          : chapter.sectionTitle!;
      if (title != current) {
        current = title;
        rows.add((title: title, chapter: null));
      }
      rows.add((title: null, chapter: chapter));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.76,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '章节目录',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                Text('${catalog.length} 章'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('chapter-catalog-list'),
              itemCount: _rows.length,
              itemBuilder: (context, index) {
                final row = _rows[index];
                final chapter = row.chapter;
                if (chapter == null) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                    child: Text(
                      row.title!,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                }
                final active = chapter.id == activeChapterId;
                final loaded = loadedChapterIds.contains(chapter.id);
                return ListTile(
                  key: ValueKey('catalog-chapter-${chapter.id}'),
                  selected: active,
                  leading: CircleAvatar(child: Text('${chapter.index}')),
                  title: Text(chapter.chineseTitle),
                  subtitle: Text(
                    chapter.japaneseTitle,
                    locale: const Locale('ja', 'JP'),
                  ),
                  trailing: active
                      ? const Icon(Icons.menu_book_rounded)
                      : Icon(
                          loaded
                              ? Icons.check_circle_outline_rounded
                              : Icons.cloud_download_outlined,
                          semanticLabel: loaded ? '正文已加载' : '点击后加载正文',
                        ),
                  onTap: () => Navigator.pop(context, chapter),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TranslationSourceSheet extends StatelessWidget {
  const _TranslationSourceSheet({required this.selectedSource});

  final TranslationSource selectedSource;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(
              '翻译源',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ),
          RadioGroup<TranslationSource>(
            groupValue: selectedSource,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final source in TranslationSource.values)
                  RadioListTile<TranslationSource>(
                    key: ValueKey('source-${source.name}'),
                    value: source,
                    title: Text(source.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsResult {
  const _SettingsResult({required this.settings, required this.themeMode});

  final ReaderSettings settings;
  final ThemeMode themeMode;
}

class _ReaderSettingsSheet extends StatefulWidget {
  const _ReaderSettingsSheet({required this.settings, required this.themeMode});

  final ReaderSettings settings;
  final ThemeMode themeMode;

  @override
  State<_ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<_ReaderSettingsSheet> {
  late ReaderSettings _draft;
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _draft = widget.settings;
    _themeMode = widget.themeMode;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.88,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '阅读样式',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [
                _SectionLabel('内容'),
                const SizedBox(height: 10),
                SegmentedButton<ReadingMode>(
                  key: const ValueKey('settings-reading-mode'),
                  segments: [
                    for (final mode in ReadingMode.values)
                      ButtonSegment(value: mode, label: Text(mode.label)),
                  ],
                  selected: {_draft.readingMode},
                  onSelectionChanged: (selection) {
                    setState(() {
                      _draft = _draft.copyWith(readingMode: selection.single);
                    });
                  },
                ),
                const SizedBox(height: 22),
                _SectionLabel('主题'),
                const SizedBox(height: 10),
                SegmentedButton<ThemeMode>(
                  key: const ValueKey('settings-theme-mode'),
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                    ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                  ],
                  selected: {_themeMode},
                  onSelectionChanged: (selection) {
                    setState(() => _themeMode = selection.single);
                  },
                ),
                const SizedBox(height: 22),
                _ReaderSlider(
                  label: '中文字号',
                  valueLabel: _draft.chineseFontSize.round().toString(),
                  value: _draft.chineseFontSize,
                  min: 17,
                  max: 30,
                  divisions: 13,
                  onChanged: (value) {
                    setState(
                      () => _draft = _draft.copyWith(chineseFontSize: value),
                    );
                  },
                ),
                _ReaderSlider(
                  label: '日文字号',
                  valueLabel: _draft.japaneseFontSize.round().toString(),
                  value: _draft.japaneseFontSize,
                  min: 12,
                  max: 24,
                  divisions: 12,
                  onChanged: (value) {
                    setState(
                      () => _draft = _draft.copyWith(japaneseFontSize: value),
                    );
                  },
                ),
                _ReaderSlider(
                  label: '行距',
                  valueLabel: _draft.lineHeight.toStringAsFixed(1),
                  value: _draft.lineHeight,
                  min: 1.4,
                  max: 2.2,
                  divisions: 8,
                  onChanged: (value) {
                    setState(() => _draft = _draft.copyWith(lineHeight: value));
                  },
                ),
                _ReaderSlider(
                  label: '日文透明度',
                  valueLabel: '${(_draft.japaneseOpacity * 100).round()}%',
                  value: _draft.japaneseOpacity,
                  min: 0.3,
                  max: 0.85,
                  divisions: 11,
                  onChanged: (value) {
                    setState(
                      () => _draft = _draft.copyWith(japaneseOpacity: value),
                    );
                  },
                ),
                _ReaderSlider(
                  label: '正文宽度',
                  valueLabel: '${_draft.readingWidth.round()} px',
                  value: _draft.readingWidth,
                  min: 520,
                  max: 900,
                  divisions: 19,
                  onChanged: (value) {
                    setState(
                      () => _draft = _draft.copyWith(readingWidth: value),
                    );
                  },
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: FilledButton(
                key: const ValueKey('settings-apply'),
                onPressed: () => Navigator.pop(
                  context,
                  _SettingsResult(settings: _draft, themeMode: _themeMode),
                ),
                child: const Text('应用'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _ReaderSlider extends StatelessWidget {
  const _ReaderSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                valueLabel,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _ReaderSkeleton extends StatelessWidget {
  const _ReaderSkeleton();

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.08);
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: 180, height: 24, color: base),
                const SizedBox(height: 28),
                for (final width in [1.0, 0.92, 0.78, 0.96, 0.66]) ...[
                  FractionallySizedBox(
                    widthFactor: width,
                    child: Container(height: 16, color: base),
                  ),
                  const SizedBox(height: 18),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
