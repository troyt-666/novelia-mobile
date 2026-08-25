import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show ScrollCacheExtent, ScrollDirection, SelectedContent;
import 'package:flutter/services.dart';

import '../../core/model/reader_models.dart';

typedef ReaderBookmarkChanged =
    void Function(ReadingPosition position, bool bookmarked);

@visibleForTesting
ReaderLoadDirection? readerNavigationDirectionForKey(
  LogicalKeyboardKey key,
  ReaderLayoutMode layoutMode,
) {
  if (layoutMode == ReaderLayoutMode.scroll) {
    if (key == LogicalKeyboardKey.arrowUp) return ReaderLoadDirection.before;
    if (key == LogicalKeyboardKey.arrowDown) return ReaderLoadDirection.after;
    return null;
  }
  if (key == LogicalKeyboardKey.arrowLeft) return ReaderLoadDirection.before;
  if (key == LogicalKeyboardKey.arrowRight) return ReaderLoadDirection.after;
  return null;
}

abstract interface class ReaderOrientationController {
  Future<void> apply(ReaderOrientationPreference preference);

  Future<void> reset();
}

class SystemReaderOrientationController implements ReaderOrientationController {
  const SystemReaderOrientationController();

  @override
  Future<void> apply(ReaderOrientationPreference preference) {
    return SystemChrome.setPreferredOrientations(switch (preference) {
      ReaderOrientationPreference.followDevice => DeviceOrientation.values,
      ReaderOrientationPreference.portrait => const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ],
      ReaderOrientationPreference.landscape => const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    });
  }

  @override
  Future<void> reset() =>
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    required this.novel,
    required this.themeMode,
    required this.onThemeModeChanged,
    this.initialPosition,
    this.startAtChapterTitle = false,
    this.onPositionChanged,
    this.onExitPosition,
    this.initialBookmarkedBlockIds = const {},
    this.initialBookmarks = const [],
    this.onBookmarkChanged,
    this.initialSettings = const ReaderSettings(),
    this.onSettingsChanged,
    this.chapterDataSource,
    this.orientationController,
    super.key,
  });

  final ReaderNovel novel;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ReadingPosition? initialPosition;
  final bool startAtChapterTitle;
  final ValueChanged<ReadingPosition>? onPositionChanged;
  final ValueChanged<ReadingPosition>? onExitPosition;
  final Set<String> initialBookmarkedBlockIds;
  final List<ReadingPosition> initialBookmarks;
  final ReaderBookmarkChanged? onBookmarkChanged;
  final ReaderSettings initialSettings;
  final ValueChanged<ReaderSettings>? onSettingsChanged;
  final ReaderChapterDataSource? chapterDataSource;
  final ReaderOrientationController? orientationController;

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
  final _verticalScrollController = ScrollController();
  final _pageController = PageController();
  final _keyboardFocusNode = FocusNode(
    debugLabel: 'reader-keyboard-navigation',
  );
  final _viewportKey = GlobalKey(debugLabel: 'reader-viewport');
  final _anchorBlockId = RestorableStringN(null);
  late final RestorableInt _modeIndex;
  late final RestorableInt _sourceIndex;
  late final RestorableInt _layoutIndex;
  late final RestorableInt _paletteIndex;
  late final RestorableInt _fontFamilyIndex;
  late final RestorableBool _bodyBold;
  late final RestorableDouble _chineseFontSize;
  late final RestorableDouble _japaneseFontSize;
  late final RestorableDouble _lineHeight;
  late final RestorableDouble _paragraphSpacing;
  late final RestorableDouble _japaneseOpacity;
  late final RestorableDouble _pageMargin;
  late final RestorableDouble _readingWidth;
  late final RestorableInt _columnLayoutIndex;
  late final RestorableInt _orientationIndex;
  late final RestorableBool _textSelectionEnabled;
  late final RestorableBool _tapPageTurnEnabled;
  final Set<String> _bookmarks = {};
  final Map<String, ReadingPosition> _bookmarkPositions = {};
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
  bool _turningPage = false;
  bool _selectionActive = false;
  final Map<String, int> _horizontalPageByStableId = {};
  final Map<String, List<_ReaderHorizontalLocation>>
  _horizontalLocationsByStableId = {};
  List<_ReaderHorizontalPage> _horizontalPages = const [];
  int _metricsRelayoutGeneration = 0;
  late ReaderOrientationController _orientationController;

  ScrollController get _activeScrollController =>
      _settings.layoutMode == ReaderLayoutMode.pages
      ? _pageController
      : _verticalScrollController;

  @override
  String? get restorationId => 'reader:${widget.novel.id}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settings = widget.initialSettings;
    _modeIndex = RestorableInt(_settings.readingMode.index);
    _sourceIndex = RestorableInt(_settings.translationSource.index);
    _layoutIndex = RestorableInt(_settings.layoutMode.index);
    _paletteIndex = RestorableInt(_settings.palette.index);
    _fontFamilyIndex = RestorableInt(_settings.fontFamily.index);
    _bodyBold = RestorableBool(_settings.bodyBold);
    _chineseFontSize = RestorableDouble(_settings.chineseFontSize);
    _japaneseFontSize = RestorableDouble(_settings.japaneseFontSize);
    _lineHeight = RestorableDouble(_settings.lineHeight);
    _paragraphSpacing = RestorableDouble(_settings.paragraphSpacing);
    _japaneseOpacity = RestorableDouble(_settings.japaneseOpacity);
    _pageMargin = RestorableDouble(_settings.pageMargin);
    _readingWidth = RestorableDouble(_settings.readingWidth);
    _columnLayoutIndex = RestorableInt(_settings.columnLayout.index);
    _orientationIndex = RestorableInt(_settings.orientationPreference.index);
    _textSelectionEnabled = RestorableBool(_settings.textSelectionEnabled);
    _tapPageTurnEnabled = RestorableBool(_settings.tapPageTurnEnabled);
    _orientationController =
        widget.orientationController ??
        const SystemReaderOrientationController();
    unawaited(_orientationController.apply(_settings.orientationPreference));
    _loadedChapters = List.of(widget.novel.chapters);
    _rebuildStream();
    final initialBoundaries = _initialBoundaryStatuses();
    _beforeBoundary = initialBoundaries.$1;
    _afterBoundary = initialBoundaries.$2;
    _windowEnd = _items.length.clamp(0, _initialWindowItems);
    _bookmarks.addAll(widget.initialBookmarkedBlockIds);
    for (final position in widget.initialBookmarks) {
      _bookmarks.add(position.blockId);
      _bookmarkPositions[position.blockId] = position;
    }
    for (final chapter in _loadedChapters) {
      for (final block in chapter.blocks) {
        if (_bookmarks.contains(block.id)) {
          _bookmarkPositions.putIfAbsent(
            block.id,
            () => ReadingPosition(chapterId: chapter.id, blockId: block.id),
          );
        }
      }
    }
    _activeChapterId =
        widget.initialPosition?.chapterId ??
        (_loadedChapters.isEmpty ? null : _loadedChapters.first.id);
    _lastPosition = _resolvedInitialPosition();
    widget.chapterDataSource?.addChapterUpdateListener(_onChapterUpdated);
  }

  @override
  void didUpdateWidget(ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.orientationController != widget.orientationController) {
      unawaited(_orientationController.reset());
      _orientationController =
          widget.orientationController ??
          const SystemReaderOrientationController();
      unawaited(_orientationController.apply(_settings.orientationPreference));
    }
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
    registerForRestoration(_layoutIndex, 'layout-mode');
    registerForRestoration(_paletteIndex, 'reader-palette');
    registerForRestoration(_fontFamilyIndex, 'font-family');
    registerForRestoration(_bodyBold, 'body-bold');
    registerForRestoration(_chineseFontSize, 'chinese-font-size');
    registerForRestoration(_japaneseFontSize, 'japanese-font-size');
    registerForRestoration(_lineHeight, 'line-height');
    registerForRestoration(_paragraphSpacing, 'paragraph-spacing');
    registerForRestoration(_japaneseOpacity, 'japanese-opacity');
    registerForRestoration(_pageMargin, 'page-margin');
    registerForRestoration(_readingWidth, 'reading-width');
    registerForRestoration(_columnLayoutIndex, 'column-layout');
    registerForRestoration(_orientationIndex, 'orientation-preference');
    registerForRestoration(_textSelectionEnabled, 'text-selection-enabled');
    registerForRestoration(_tapPageTurnEnabled, 'tap-page-turn-enabled');

    _anchorBlockId.value ??= widget.initialPosition?.blockId;
    _settings = _settings.copyWith(
      readingMode: ReadingMode.values[_modeIndex.value],
      translationSource: TranslationSource.values[_sourceIndex.value],
      layoutMode: ReaderLayoutMode.values[_layoutIndex.value],
      palette: ReaderPalette.values[_paletteIndex.value],
      fontFamily: ReaderFontFamily.values[_fontFamilyIndex.value],
      bodyBold: _bodyBold.value,
      chineseFontSize: _chineseFontSize.value,
      japaneseFontSize: _japaneseFontSize.value,
      lineHeight: _lineHeight.value,
      paragraphSpacing: _paragraphSpacing.value,
      japaneseOpacity: _japaneseOpacity.value,
      pageMargin: _pageMargin.value,
      readingWidth: _readingWidth.value,
      columnLayout: ReaderColumnLayout.values[_columnLayoutIndex.value],
      orientationPreference:
          ReaderOrientationPreference.values[_orientationIndex.value],
      textSelectionEnabled: _textSelectionEnabled.value,
      tapPageTurnEnabled: _tapPageTurnEnabled.value,
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
  void didChangeMetrics() {
    if (!mounted || _restoring) return;
    final anchor = _captureAnchor(notify: false, updateUi: false);
    final position = anchor == null ? null : _lastPosition;
    if (position == null) return;
    final generation = ++_metricsRelayoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _metricsRelayoutGeneration) return;
      await _jumpToStableId(
        'block:${position.blockId}',
        intraBlockOffset: position.intraBlockOffset,
      );
    });
  }

  @override
  void dispose() {
    widget.chapterDataSource?.removeChapterUpdateListener(_onChapterUpdated);
    unawaited(_orientationController.reset());
    _windowGeneration += 1;
    _chromeDismissTimer?.cancel();
    if (!_restoring) {
      final position = _lastPosition;
      if (position != null) {
        (widget.onExitPosition ?? widget.onPositionChanged)?.call(position);
      }
    }
    WidgetsBinding.instance.removeObserver(this);
    _verticalScrollController.dispose();
    _pageController.dispose();
    _keyboardFocusNode.dispose();
    _anchorBlockId.dispose();
    _modeIndex.dispose();
    _sourceIndex.dispose();
    _layoutIndex.dispose();
    _paletteIndex.dispose();
    _fontFamilyIndex.dispose();
    _bodyBold.dispose();
    _chineseFontSize.dispose();
    _japaneseFontSize.dispose();
    _lineHeight.dispose();
    _paragraphSpacing.dispose();
    _japaneseOpacity.dispose();
    _pageMargin.dispose();
    _readingWidth.dispose();
    _columnLayoutIndex.dispose();
    _orientationIndex.dispose();
    _textSelectionEnabled.dispose();
    _tapPageTurnEnabled.dispose();
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
      if (widget.startAtChapterTitle && _activeChapterId != null) {
        final chapterStableId = 'chapter:$_activeChapterId';
        if (_itemIndices.containsKey(chapterStableId)) {
          stableId = chapterStableId;
          final chapter = _loadedChapters
              .where((chapter) => chapter.id == _activeChapterId)
              .firstOrNull;
          _anchorBlockId.value = chapter?.blocks.firstOrNull?.id;
        }
      } else if (blockId != null) {
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
        await _jumpToStableId(
          stableId,
          intraBlockOffset: restoreOffset,
          alignment: widget.startAtChapterTitle ? 0.1 : 0,
        );
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
    double alignment = 0,
  }) async {
    if (!mounted) return;
    final targetIndex = _itemIndices[stableId];
    if (targetIndex == null || !_activeScrollController.hasClients) return;

    if (_settings.layoutMode == ReaderLayoutMode.pages) {
      final page = _horizontalPageForStableId(stableId, intraBlockOffset);
      if (page != null && _pageController.hasClients) {
        _pageController.jumpToPage(page);
        await WidgetsBinding.instance.endOfFrame;
      }
      return;
    }

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
        alignment: alignment,
        duration: Duration.zero,
      );
      if (intraBlockOffset > 0 &&
          _settings.layoutMode == ReaderLayoutMode.scroll &&
          _verticalScrollController.hasClients &&
          targetContext.mounted) {
        final box = targetContext.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          final extra = box.size.height * intraBlockOffset / 1000.0;
          final position = _verticalScrollController.position;
          _verticalScrollController.jumpTo(
            (position.pixels + extra).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
      }
    }
  }

  int? _horizontalPageForStableId(String stableId, int intraBlockOffset) {
    final locations = _horizontalLocationsByStableId[stableId];
    if (locations == null || locations.isEmpty) {
      return _horizontalPageByStableId[stableId];
    }
    var selected = locations.first;
    for (final location in locations.skip(1)) {
      if (location.intraBlockOffset > intraBlockOffset) break;
      selected = location;
    }
    return selected.pageIndex;
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
        !_activeScrollController.hasClients) {
      return;
    }
    _adjustingWindow = true;
    final controller = _activeScrollController;
    final oldMaxExtent = controller.position.maxScrollExtent;
    final oldPixels = controller.position.pixels;
    setState(() {
      _windowStart = (_windowStart - _windowExpansionItems).clamp(
        0,
        _windowEnd,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final addedExtent = controller.position.maxScrollExtent - oldMaxExtent;
      final target = (oldPixels + addedExtent).clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      );
      controller.jumpTo(target);
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
    final controller = _activeScrollController;
    if (renderedAnchorIndex != null && controller.hasClients) {
      final oldMaxExtent = controller.position.maxScrollExtent;
      final oldPixels = controller.position.pixels;
      setState(() {
        _windowStart = (renderedAnchorIndex! - _windowLeadInItems).clamp(
          0,
          _windowEnd,
        );
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !controller.hasClients) return;
      final addedExtent = controller.position.maxScrollExtent - oldMaxExtent;
      final position = controller.position;
      controller.jumpTo(
        (oldPixels + addedExtent).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !controller.hasClients) return;
    }
    if (visibleAnchor != null && controller.hasClients) {
      var itemContext = _mountedContextFor(visibleAnchor.stableId);
      if (itemContext == null) {
        await _jumpToStableId(
          visibleAnchor.stableId,
          intraBlockOffset: visibleAnchor.intraBlockOffset,
        );
        if (!mounted || !controller.hasClients) return;
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !controller.hasClients) return;
        itemContext = _mountedContextFor(visibleAnchor.stableId);
      }
      if (itemContext != null && itemContext.mounted) {
        await Scrollable.ensureVisible(
          itemContext,
          alignment: 0,
          duration: Duration.zero,
        );
        if (!mounted || !controller.hasClients) return;
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !controller.hasClients) return;
      }
      final viewportContext = _viewportKey.currentContext;
      final itemBox = itemContext?.findRenderObject();
      final viewportBox = viewportContext?.findRenderObject();
      if (itemBox is RenderBox &&
          itemBox.hasSize &&
          viewportBox is RenderBox &&
          viewportBox.hasSize) {
        final itemOrigin = itemBox.localToGlobal(Offset.zero);
        final viewportOrigin = viewportBox.localToGlobal(Offset.zero);
        final newOffset = _settings.layoutMode == ReaderLayoutMode.pages
            ? itemOrigin.dx - viewportOrigin.dx
            : itemOrigin.dy - viewportOrigin.dy;
        final correction = newOffset - visibleAnchor.viewportOffset;
        final position = controller.position;
        controller.jumpTo(
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
    if (_settings.layoutMode == ReaderLayoutMode.pages && anchor != null) {
      return _VisibleReaderAnchor(
        stableId: anchor.stableId,
        intraBlockOffset: _lastPosition?.intraBlockOffset ?? 0,
        viewportOffset: 0,
      );
    }
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
    final itemOrigin = itemBox.localToGlobal(Offset.zero);
    final viewportOrigin = viewportBox.localToGlobal(Offset.zero);
    return _VisibleReaderAnchor(
      stableId: anchor.stableId,
      intraBlockOffset: _lastPosition?.intraBlockOffset ?? 0,
      viewportOffset: _settings.layoutMode == ReaderLayoutMode.pages
          ? itemOrigin.dx - viewportOrigin.dx
          : itemOrigin.dy - viewportOrigin.dy,
    );
  }

  AlignedBlockItem? _captureAnchor({bool notify = true, bool updateUi = true}) {
    if (_settings.layoutMode == ReaderLayoutMode.pages) {
      return _captureHorizontalAnchor(notify: notify, updateUi: updateUi);
    }
    final viewportContext = _viewportKey.currentContext;
    if (viewportContext == null) return null;
    final viewportBox = viewportContext.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;

    final horizontal = _settings.layoutMode == ReaderLayoutMode.pages;
    final viewportOrigin = viewportBox.localToGlobal(Offset.zero);
    final viewportStart = horizontal ? viewportOrigin.dx : viewportOrigin.dy;
    final viewportExtent = horizontal
        ? viewportBox.size.width
        : viewportBox.size.height;
    final viewportEnd = viewportStart + viewportExtent;
    AlignedBlockItem? firstSubstantiallyVisible;
    AlignedBlockItem? nearestVisible;
    var nearestLeadingEdge = double.infinity;

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
      final itemOrigin = renderObject.localToGlobal(Offset.zero);
      final itemStart = horizontal ? itemOrigin.dx : itemOrigin.dy;
      final itemExtent = horizontal
          ? renderObject.size.width
          : renderObject.size.height;
      final itemEnd = itemStart + itemExtent;
      final visibleExtent =
          (itemEnd.clamp(viewportStart, viewportEnd) -
                  itemStart.clamp(viewportStart, viewportEnd))
              .clamp(0.0, itemExtent);
      if (visibleExtent <= 0) continue;

      final distanceFromLeadingEdge = (itemStart - viewportStart).abs();
      if (distanceFromLeadingEdge < nearestLeadingEdge) {
        nearestLeadingEdge = distanceFromLeadingEdge;
        nearestVisible = item;
      }
      if (firstSubstantiallyVisible == null &&
          visibleExtent >= itemExtent * 0.35) {
        firstSubstantiallyVisible = item;
      }
    }

    final anchor = firstSubstantiallyVisible ?? nearestVisible;
    if (anchor == null) return null;
    var intraBlockOffset = 0;
    final anchorContext = _mountedContextFor(anchor.stableId);
    final anchorBox = anchorContext?.findRenderObject();
    if (!horizontal &&
        anchorBox is RenderBox &&
        anchorBox.hasSize &&
        anchorBox.size.height > 0) {
      final top = anchorBox.localToGlobal(Offset.zero).dy;
      final pixelsIntoBlock = (viewportStart - top).clamp(
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

  AlignedBlockItem? _captureHorizontalAnchor({
    required bool notify,
    required bool updateUi,
  }) {
    if (_horizontalPages.isEmpty || !_pageController.hasClients) return null;
    final pageIndex = (_pageController.page?.round() ?? 0).clamp(
      0,
      _horizontalPages.length - 1,
    );
    final page = _horizontalPages[pageIndex];
    final anchor = page.anchor;
    if (anchor == null) return null;
    final position = ReadingPosition(
      chapterId: anchor.chapter.id,
      blockId: anchor.block.id,
      intraBlockOffset: page.anchorIntraBlockOffset,
    );
    final changed = _lastPosition != position;
    _anchorBlockId.value = anchor.block.id;
    _lastPosition = position;
    final chapterChanged = _activeChapterId != anchor.chapter.id;
    _activeChapterId = anchor.chapter.id;
    if (chapterChanged && updateUi && mounted) setState(() {});
    if (notify && changed) widget.onPositionChanged?.call(position);
    return anchor;
  }

  Future<void> _applySettings(
    ReaderSettings settings, {
    ThemeMode? themeMode,
    bool notify = true,
  }) async {
    final anchor = _captureAnchor();
    final orientationChanged =
        settings.orientationPreference != _settings.orientationPreference;
    setState(() {
      _settings = settings;
      if (!settings.textSelectionEnabled) _selectionActive = false;
      _restoring = true;
      _modeIndex.value = settings.readingMode.index;
      _sourceIndex.value = settings.translationSource.index;
      _layoutIndex.value = settings.layoutMode.index;
      _paletteIndex.value = settings.palette.index;
      _fontFamilyIndex.value = settings.fontFamily.index;
      _bodyBold.value = settings.bodyBold;
      _chineseFontSize.value = settings.chineseFontSize;
      _japaneseFontSize.value = settings.japaneseFontSize;
      _lineHeight.value = settings.lineHeight;
      _paragraphSpacing.value = settings.paragraphSpacing;
      _japaneseOpacity.value = settings.japaneseOpacity;
      _pageMargin.value = settings.pageMargin;
      _readingWidth.value = settings.readingWidth;
      _columnLayoutIndex.value = settings.columnLayout.index;
      _orientationIndex.value = settings.orientationPreference.index;
      _textSelectionEnabled.value = settings.textSelectionEnabled;
      _tapPageTurnEnabled.value = settings.tapPageTurnEnabled;
    });
    if (orientationChanged) {
      await _orientationController.apply(settings.orientationPreference);
    }
    if (themeMode != null && themeMode != widget.themeMode) {
      widget.onThemeModeChanged(themeMode);
    }
    if (notify) widget.onSettingsChanged?.call(settings);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (anchor != null) {
      await _jumpToStableId(
        anchor.stableId,
        intraBlockOffset: _lastPosition?.intraBlockOffset ?? 0,
      );
      if (!mounted) return;
    }
    setState(() => _restoring = false);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_keyboardFocusNode.hasFocus) _keyboardFocusNode.requestFocus();
    if (_selectionActive) return;
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

  void _handleSelectionChanged(SelectedContent? content) {
    _selectionActive = content?.plainText.isNotEmpty ?? false;
    if (_selectionActive) _clearTapCandidate();
  }

  void _handleReadingTap(Offset point) {
    if (_chromeVisible) {
      _hideChrome();
      return;
    }
    final size = MediaQuery.sizeOf(context);
    final inHorizontalCenter =
        point.dx >= size.width * 0.25 && point.dx <= size.width * 0.75;
    if (inHorizontalCenter) {
      _showChrome();
      return;
    }
    if (!_settings.tapPageTurnEnabled) return;
    unawaited(
      _turnPage(
        point.dx < size.width * 0.25
            ? ReaderLoadDirection.before
            : ReaderLoadDirection.after,
      ),
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    if (!mounted || _selectionActive) return;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return;
    }
    final direction = readerNavigationDirectionForKey(
      event.logicalKey,
      _settings.layoutMode,
    );
    if (direction == null) return;
    unawaited(_turnPage(direction));
  }

  Future<void> _turnPage(ReaderLoadDirection direction) async {
    if (_turningPage || _restoring || !_activeScrollController.hasClients) {
      return;
    }
    _turningPage = true;
    try {
      final controller = _activeScrollController;
      var position = controller.position;
      final forward = direction == ReaderLoadDirection.after;
      final atAvailableEdge = forward
          ? position.extentAfter <= 1
          : position.extentBefore <= 1;
      final boundary = forward ? _afterBoundary : _beforeBoundary;
      if (atAvailableEdge && boundary == ReaderBoundaryStatus.loadable) {
        await _requestAdjacent(direction);
        if (!mounted) return;
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !controller.hasClients) return;
        position = controller.position;
      }

      _hideChrome();
      if (_settings.layoutMode == ReaderLayoutMode.pages) {
        final currentPage = _pageController.page?.round() ?? 0;
        final lastPage = position.viewportDimension <= 0
            ? 0
            : (position.maxScrollExtent / position.viewportDimension).round();
        final targetPage = (currentPage + (forward ? 1 : -1)).clamp(
          0,
          lastPage,
        );
        if (targetPage == currentPage) return;
        await _pageController.animateToPage(
          targetPage,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        final overlap = (position.viewportDimension * 0.08).clamp(40.0, 72.0);
        final step = (position.viewportDimension - overlap).clamp(
          120.0,
          position.viewportDimension,
        );
        final target = (position.pixels + (forward ? step : -step)).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((target - position.pixels).abs() < 0.5) return;
        await _verticalScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      }
      if (mounted) _captureAnchor(notify: true);
    } finally {
      _turningPage = false;
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

  void _openCatalogIndex(int index) {
    final catalog = _chapterCatalog;
    if (index < 0 || index >= catalog.length) return;
    _scheduleChromeDismiss();
    unawaited(_openCatalogEntry(catalog[index]));
  }

  Future<void> _showCatalog() async {
    final target = await showModalBottomSheet<_ReaderNavigationTarget>(
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
        loadedChapters: _loadedChapters,
        bookmarks: _bookmarkPositions.values.toList(growable: false),
        settings: _settings,
        onBookmarkRemoved: (position) => _setBookmark(position, false),
      ),
    );
    if (target == null || !mounted) return;
    await _openCatalogEntry(target.chapter, position: target.position);
  }

  Future<void> _openCatalogEntry(
    ReaderChapterCatalogEntry entry, {
    ReadingPosition? position,
  }) async {
    if (_catalogLoading) return;
    final loadedChapter = _loadedChapters
        .where((chapter) => chapter.id == entry.id && chapter.blocks.isNotEmpty)
        .firstOrNull;
    if (loadedChapter != null) {
      await _jumpToLoadedPosition(loadedChapter, position);
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
      await _jumpToLoadedPosition(selected, position);
    } catch (error) {
      if (!mounted || requestGeneration != _windowGeneration) return;
      setState(() {
        _catalogLoading = false;
        _catalogLoadError = error;
        _catalogRetryEntry = entry;
      });
    }
  }

  Future<void> _jumpToLoadedPosition(
    NovelChapter chapter,
    ReadingPosition? requested,
  ) async {
    setState(() => _restoring = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final requestedBlock = requested?.chapterId == chapter.id
        ? chapter.blocks
              .where((block) => block.id == requested!.blockId)
              .firstOrNull
        : null;
    await _jumpToStableId(
      requestedBlock == null
          ? 'chapter:${chapter.id}'
          : 'block:${requestedBlock.id}',
      intraBlockOffset: requestedBlock == null
          ? 0
          : requested!.intraBlockOffset,
    );
    if (!mounted) return;
    final targetBlock = requestedBlock ?? chapter.blocks.firstOrNull;
    if (targetBlock != null) {
      _anchorBlockId.value = targetBlock.id;
      _activeChapterId = chapter.id;
      _lastPosition = ReadingPosition(
        chapterId: chapter.id,
        blockId: targetBlock.id,
        intraBlockOffset: requestedBlock == null
            ? 0
            : requested!.intraBlockOffset,
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
    final originalSettings = _settings;
    final result = await showModalBottomSheet<_SettingsResult>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ReaderSettingsSheet(
        settings: _settings,
        onPreview: (settings) {
          unawaited(_applySettings(settings, notify: false));
        },
      ),
    );
    if (!mounted) return;
    if (result == null) {
      await _applySettings(originalSettings, notify: false);
      return;
    }
    await _applySettings(result.settings);
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
    _setBookmark(position, bookmarked);
  }

  void _setBookmark(ReadingPosition position, bool bookmarked) {
    setState(() {
      if (bookmarked) {
        _bookmarks.add(position.blockId);
        _bookmarkPositions[position.blockId] = position;
      } else {
        _bookmarks.remove(position.blockId);
        _bookmarkPositions.remove(position.blockId);
      }
    });
    widget.onBookmarkChanged?.call(position, bookmarked);
  }

  int get _readerItemCount =>
      _windowEnd -
      _windowStart +
      (_windowStart == 0 ? 1 : 0) +
      (_windowEnd == _items.length ? 1 : 0);

  int? _streamIndexForReaderItem(int index) {
    final showBeforeBoundary = _windowStart == 0;
    if (showBeforeBoundary && index == 0) return null;
    final streamIndex = index - (showBeforeBoundary ? 1 : 0);
    if (streamIndex >= _windowEnd - _windowStart) return null;
    return _windowStart + streamIndex;
  }

  String? _stableIdForReaderItem(int index) {
    final streamIndex = _streamIndexForReaderItem(index);
    return streamIndex == null ? null : _items[streamIndex].stableId;
  }

  Widget _buildReaderItem(BuildContext context, int index, Color foreground) {
    final showBeforeBoundary = _windowStart == 0;
    if (showBeforeBoundary && index == 0) {
      return _ReaderAvailabilityBoundary(
        direction: ReaderLoadDirection.before,
        status: _beforeBoundary,
        loading: _beforeLoading,
        error: _beforeLoadError,
        onRetry: () => unawaited(_requestAdjacent(ReaderLoadDirection.before)),
      );
    }
    final streamIndex = index - (showBeforeBoundary ? 1 : 0);
    if (streamIndex >= _windowEnd - _windowStart) {
      return _ReaderAvailabilityBoundary(
        direction: ReaderLoadDirection.after,
        status: _afterBoundary,
        loading: _afterLoading,
        error: _afterLoadError,
        onRetry: () => unawaited(_requestAdjacent(ReaderLoadDirection.after)),
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
        bookmarked: _bookmarks.contains(item.block.id),
        onMounted: (itemContext) {
          _mountedBlockIds.add(item.block.id);
          _registerMountedItem(item.stableId, itemContext);
        },
        onUnmounted: (itemContext) {
          _mountedBlockIds.remove(item.block.id);
          _unregisterMountedItem(item.stableId, itemContext);
        },
      ),
    };
  }

  double _measureTextHeight(
    BuildContext context,
    String text,
    TextStyle style,
    double width, {
    Locale? locale,
  }) {
    if (text.isEmpty) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      locale: locale,
    )..layout(maxWidth: math.max(1, width));
    return painter.height;
  }

  double _estimateReaderItemHeight(
    BuildContext context,
    int index,
    double viewportWidth,
  ) {
    final streamIndex = _streamIndexForReaderItem(index);
    if (streamIndex == null) return 76;
    final item = _items[streamIndex];
    if (item is ChapterBoundaryItem) {
      final titleWidth = math.max(
        1.0,
        math.min(viewportWidth, _settings.readingWidth) -
            _settings.pageMargin * 2,
      );
      final family = _settings.fontFamily == ReaderFontFamily.systemSerif
          ? 'serif'
          : null;
      return 128 +
          _measureTextHeight(
            context,
            item.chapter.chineseTitle,
            TextStyle(
              fontSize: 27,
              height: 1.3,
              fontWeight: FontWeight.w700,
              fontFamily: family,
            ),
            titleWidth,
            locale: const Locale('zh', 'CN'),
          ) +
          _measureTextHeight(
            context,
            item.chapter.japaneseTitle,
            const TextStyle(fontSize: 15, height: 1.4),
            titleWidth,
            locale: const Locale('ja', 'JP'),
          ) +
          (item.chapter.translationState(_settings.translationSource) ==
                  TranslationState.complete
              ? 0
              : 82);
    }
    if (item is! AlignedBlockItem) return 0;
    final block = item.block;
    final availableWidth = math.min(viewportWidth, _settings.readingWidth);
    if (block.kind == AlignedBlockKind.illustration) {
      return math.max(180.0, (availableWidth - 32) / 0.75 + 32);
    }
    final translationState = item.chapter.translationState(
      _settings.translationSource,
    );
    final translation = translationState == TranslationState.complete
        ? block.translationFor(_settings.translationSource)
        : null;
    final showJapanese =
        translation == null ||
        _settings.readingMode == ReadingMode.chineseJapanese;
    final dialogue = block.kind == AlignedBlockKind.dialogue;
    final horizontalPadding = _settings.pageMargin * 2 + (dialogue ? 16 : 0);
    final textWidth = math.max(1.0, availableWidth - horizontalPadding);
    final parallel =
        translation != null &&
        showJapanese &&
        _usesParallelColumns(_settings, viewportWidth);
    final bodyWeight = _settings.bodyBold ? FontWeight.w600 : FontWeight.w400;
    final family = _settings.fontFamily == ReaderFontFamily.systemSerif
        ? 'serif'
        : null;
    final columnWidth = parallel
        ? math.max(1.0, (textWidth - 28) / 2)
        : textWidth;
    final chineseHeight = translation == null
        ? 0.0
        : _measureTextHeight(
            context,
            translation,
            TextStyle(
              fontSize: _settings.chineseFontSize,
              height: _settings.lineHeight,
              fontWeight: bodyWeight,
              fontFamily: family,
              letterSpacing: 0.15,
            ),
            columnWidth,
            locale: const Locale('zh', 'CN'),
          );
    final japaneseHeight = !showJapanese
        ? 0.0
        : _measureTextHeight(
            context,
            block.japanese,
            TextStyle(
              fontSize: translation == null
                  ? _settings.chineseFontSize * 0.92
                  : _settings.japaneseFontSize,
              height: _settings.lineHeight,
              fontWeight: bodyWeight,
              fontFamily: family,
            ),
            columnWidth,
            locale: const Locale('ja', 'JP'),
          );
    final textHeight = parallel
        ? math.max(chineseHeight, japaneseHeight)
        : chineseHeight +
              japaneseHeight +
              (chineseHeight > 0 && japaneseHeight > 0
                  ? _settings.chineseFontSize * 0.42
                  : 0);
    return 9 + textHeight + _settings.paragraphSpacing + 4;
  }

  List<_ReaderHorizontalPage> _composeHorizontalPages(
    BuildContext context,
    double viewportWidth,
    double availableHeight,
  ) {
    final pages = <_ReaderHorizontalPage>[];
    var entries = <_ReaderHorizontalEntry>[];
    var estimatedHeight = 0.0;
    _horizontalPageByStableId.clear();
    _horizontalLocationsByStableId.clear();

    void finishPage() {
      if (entries.isEmpty) return;
      final pageIndex = pages.length;
      AlignedBlockItem? anchor;
      var anchorIntraBlockOffset = 0;
      for (final entry in entries) {
        final stableId = _stableIdForReaderItem(entry.readerItemIndex);
        if (stableId == null) continue;
        _horizontalPageByStableId.putIfAbsent(stableId, () => pageIndex);
        final location = _ReaderHorizontalLocation(
          pageIndex: pageIndex,
          intraBlockOffset: entry.fragment?.intraBlockOffset ?? 0,
        );
        _horizontalLocationsByStableId
            .putIfAbsent(stableId, () => [])
            .add(location);
        if (anchor != null) continue;
        final streamIndex = _streamIndexForReaderItem(entry.readerItemIndex);
        if (streamIndex == null) continue;
        final item = _items[streamIndex];
        if (item is AlignedBlockItem) {
          anchor = item;
          anchorIntraBlockOffset = location.intraBlockOffset;
        } else if (item is ChapterBoundaryItem) {
          final firstBlock = item.chapter.blocks.firstOrNull;
          if (firstBlock != null) {
            anchor = AlignedBlockItem(chapter: item.chapter, block: firstBlock);
          }
        }
      }
      pages.add(
        _ReaderHorizontalPage(
          entries: entries,
          anchor: anchor,
          anchorIntraBlockOffset: anchorIntraBlockOffset,
        ),
      );
      entries = <_ReaderHorizontalEntry>[];
      estimatedHeight = 0;
    }

    void addEntry(_ReaderHorizontalEntry entry, double height) {
      if (entries.isNotEmpty && estimatedHeight + height > availableHeight) {
        finishPage();
      }
      entries.add(entry);
      estimatedHeight += height;
    }

    for (var index = 0; index < _readerItemCount; index++) {
      final itemHeight = _estimateReaderItemHeight(
        context,
        index,
        viewportWidth,
      );
      final streamIndex = _streamIndexForReaderItem(index);
      final item = streamIndex == null ? null : _items[streamIndex];
      if (item is AlignedBlockItem &&
          item.block.kind != AlignedBlockKind.illustration &&
          itemHeight > availableHeight) {
        finishPage();
        for (final entry in _fragmentHorizontalBlock(
          context,
          index,
          item,
          viewportWidth,
          availableHeight,
        )) {
          addEntry(entry, entry.fragment!.estimatedHeight);
        }
        continue;
      }
      if (itemHeight > availableHeight) {
        finishPage();
        addEntry(
          _ReaderHorizontalEntry(readerItemIndex: index, scaleToFit: true),
          availableHeight,
        );
        finishPage();
        continue;
      }
      addEntry(_ReaderHorizontalEntry(readerItemIndex: index), itemHeight);
    }
    finishPage();
    if (pages.isEmpty) {
      pages.add(
        const _ReaderHorizontalPage(
          entries: [],
          anchor: null,
          anchorIntraBlockOffset: 0,
        ),
      );
    }
    _horizontalPages = pages;
    return pages;
  }

  List<_ReaderHorizontalEntry> _fragmentHorizontalBlock(
    BuildContext context,
    int readerItemIndex,
    AlignedBlockItem item,
    double viewportWidth,
    double availableHeight,
  ) {
    final translationState = item.chapter.translationState(
      _settings.translationSource,
    );
    final translation = translationState == TranslationState.complete
        ? item.block.translationFor(_settings.translationSource)
        : null;
    final showJapanese =
        translation == null ||
        _settings.readingMode == ReadingMode.chineseJapanese;
    final dialogue = item.block.kind == AlignedBlockKind.dialogue;
    final availableWidth = math.min(viewportWidth, _settings.readingWidth);
    final textWidth = math.max(
      1.0,
      availableWidth - _settings.pageMargin * 2 - (dialogue ? 16.0 : 0.0),
    );
    final parallel =
        translation != null &&
        showJapanese &&
        _usesParallelColumns(_settings, viewportWidth);
    final columnWidth = parallel
        ? math.max(1.0, (textWidth - 28) / 2)
        : textWidth;
    final bodyWeight = _settings.bodyBold ? FontWeight.w600 : FontWeight.w400;
    final family = _settings.fontFamily == ReaderFontFamily.systemSerif
        ? 'serif'
        : null;
    final chineseStyle = TextStyle(
      fontSize: _settings.chineseFontSize,
      height: _settings.lineHeight,
      fontWeight: bodyWeight,
      fontFamily: family,
      letterSpacing: 0.15,
    );
    final japaneseStyle = TextStyle(
      fontSize: translation == null
          ? _settings.chineseFontSize * 0.92
          : _settings.japaneseFontSize,
      height: _settings.lineHeight,
      fontWeight: bodyWeight,
      fontFamily: family,
    );
    final maxTextHeight = math.max(
      1.0,
      availableHeight - 9 - _settings.paragraphSpacing,
    );
    final totalLength =
        (translation?.length ?? 0) +
        (showJapanese ? item.block.japanese.length : 0);
    final fragments = <_ReaderHorizontalEntry>[];
    var consumed = 0;

    void addFragment({String? chinese, String? japanese}) {
      final chineseHeight = chinese == null
          ? 0.0
          : _measureTextHeight(
              context,
              chinese,
              chineseStyle,
              columnWidth,
              locale: const Locale('zh', 'CN'),
            );
      final japaneseHeight = japanese == null
          ? 0.0
          : _measureTextHeight(
              context,
              japanese,
              japaneseStyle,
              columnWidth,
              locale: const Locale('ja', 'JP'),
            );
      final contentHeight = parallel
          ? math.max(chineseHeight, japaneseHeight)
          : chineseHeight + japaneseHeight;
      fragments.add(
        _ReaderHorizontalEntry(
          readerItemIndex: readerItemIndex,
          fragment: _ReaderTextFragment(
            index: fragments.length,
            chinese: chinese,
            japanese: japanese,
            intraBlockOffset: totalLength == 0
                ? 0
                : (consumed / totalLength * 1000).round().clamp(0, 1000),
            estimatedHeight: 9 + contentHeight + _settings.paragraphSpacing,
          ),
        ),
      );
      consumed += (chinese?.length ?? 0) + (japanese?.length ?? 0);
    }

    if (parallel) {
      var chineseRemaining = translation;
      var japaneseRemaining = showJapanese ? item.block.japanese : '';
      while (chineseRemaining.isNotEmpty || japaneseRemaining.isNotEmpty) {
        final chinese = _takeTextPrefixThatFits(
          context,
          chineseRemaining,
          chineseStyle,
          columnWidth,
          maxTextHeight,
          locale: const Locale('zh', 'CN'),
        );
        final japanese = _takeTextPrefixThatFits(
          context,
          japaneseRemaining,
          japaneseStyle,
          columnWidth,
          maxTextHeight,
          locale: const Locale('ja', 'JP'),
        );
        addFragment(
          chinese: chinese.isEmpty ? null : chinese,
          japanese: japanese.isEmpty ? null : japanese,
        );
        chineseRemaining = chineseRemaining.substring(chinese.length);
        japaneseRemaining = japaneseRemaining.substring(japanese.length);
      }
    } else {
      void splitLanguage(
        String text,
        TextStyle style,
        Locale locale,
        bool chinese,
      ) {
        var remaining = text;
        while (remaining.isNotEmpty) {
          final part = _takeTextPrefixThatFits(
            context,
            remaining,
            style,
            columnWidth,
            maxTextHeight,
            locale: locale,
          );
          addFragment(
            chinese: chinese ? part : null,
            japanese: chinese ? null : part,
          );
          remaining = remaining.substring(part.length);
        }
      }

      if (translation != null) {
        splitLanguage(
          translation,
          chineseStyle,
          const Locale('zh', 'CN'),
          true,
        );
      }
      if (showJapanese) {
        splitLanguage(
          item.block.japanese,
          japaneseStyle,
          const Locale('ja', 'JP'),
          false,
        );
      }
    }
    return fragments;
  }

  String _takeTextPrefixThatFits(
    BuildContext context,
    String text,
    TextStyle style,
    double width,
    double maxHeight, {
    required Locale locale,
  }) {
    if (text.isEmpty ||
        _measureTextHeight(context, text, style, width, locale: locale) <=
            maxHeight) {
      return text;
    }
    var low = 1;
    var high = text.length;
    var best = 0;
    while (low <= high) {
      var middle = (low + high) ~/ 2;
      if (middle < text.length &&
          middle > 0 &&
          _isLowSurrogate(text.codeUnitAt(middle)) &&
          _isHighSurrogate(text.codeUnitAt(middle - 1))) {
        middle -= 1;
      }
      if (middle <= 0) {
        low = 1;
        continue;
      }
      final candidate = text.substring(0, middle);
      final fits =
          _measureTextHeight(
            context,
            candidate,
            style,
            width,
            locale: locale,
          ) <=
          maxHeight;
      if (fits) {
        best = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (best > 0) return text.substring(0, best);
    final firstLength =
        text.length > 1 &&
            _isHighSurrogate(text.codeUnitAt(0)) &&
            _isLowSurrogate(text.codeUnitAt(1))
        ? 2
        : 1;
    return text.substring(0, firstLength);
  }

  bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  Widget _buildVerticalReader(Color foreground) {
    return ListView.builder(
      controller: _verticalScrollController,
      physics: const ClampingScrollPhysics(),
      scrollCacheExtent: const ScrollCacheExtent.viewport(2),
      addAutomaticKeepAlives: false,
      addSemanticIndexes: false,
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 88,
        bottom: MediaQuery.paddingOf(context).bottom + 164,
      ),
      itemCount: _readerItemCount,
      itemBuilder: (context, index) =>
          _buildReaderItem(context, index, foreground),
    );
  }

  Widget _buildHorizontalReader(Color foreground) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaPadding = MediaQuery.paddingOf(context);
        // Page content should use the book surface, not permanently reserve
        // the transient chrome's full footprint. The chrome overlays pages
        // while visible and disappears during reading.
        final topPadding = mediaPadding.top + 44;
        final bottomPadding = mediaPadding.bottom + 44;
        final availableHeight = math.max(
          120.0,
          constraints.maxHeight - topPadding - bottomPadding,
        );
        final pages = _composeHorizontalPages(
          context,
          constraints.maxWidth,
          availableHeight,
        );
        return PageView.builder(
          key: const ValueKey('reader-horizontal-pages'),
          controller: _pageController,
          scrollDirection: Axis.horizontal,
          physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
          // Offscreen pages contain selectable paragraphs too. Build them on
          // demand so the active SelectionArea tracks only the visible page.
          allowImplicitScrolling: false,
          itemCount: pages.length,
          itemBuilder: (context, pageIndex) {
            final page = pages[pageIndex];
            return Padding(
              padding: EdgeInsets.only(top: topPadding, bottom: bottomPadding),
              child: ClipRect(
                key: ValueKey('reader-horizontal-page-$pageIndex'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in page.entries)
                      _buildHorizontalEntry(
                        context,
                        entry,
                        foreground,
                        constraints.maxWidth,
                        availableHeight,
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildHorizontalEntry(
    BuildContext context,
    _ReaderHorizontalEntry entry,
    Color foreground,
    double viewportWidth,
    double availableHeight,
  ) {
    final fragment = entry.fragment;
    if (fragment != null) {
      final streamIndex = _streamIndexForReaderItem(entry.readerItemIndex);
      final item = streamIndex == null ? null : _items[streamIndex];
      if (item is AlignedBlockItem) {
        return _HorizontalAlignedBlockFragmentView(
          key: ValueKey(
            'block-${item.block.id}-horizontal-fragment-${fragment.index}',
          ),
          item: item,
          fragment: fragment,
          settings: _settings,
          foreground: foreground,
          bookmarked: _bookmarks.contains(item.block.id),
        );
      }
    }
    final child = _buildReaderItem(context, entry.readerItemIndex, foreground);
    if (!entry.scaleToFit) return child;
    return SizedBox(
      height: availableHeight,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topCenter,
        child: SizedBox(width: viewportWidth, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final readerColors = _ReaderPaletteColors.resolve(
      _settings.palette,
      theme.brightness,
    );
    final readerBackground = readerColors.background;
    final foreground = readerColors.foreground;
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
    final catalog = _chapterCatalog;
    final currentCatalogIndex = catalog.indexWhere(
      (chapter) => chapter.id == currentChapter?.id,
    );
    var chapterProgress = 0.0;
    if (currentChapter != null && currentChapter.blocks.isNotEmpty) {
      final blockIndex = currentChapter.blocks.indexWhere(
        (block) => block.id == _lastPosition?.blockId,
      );
      if (blockIndex >= 0) {
        final intraBlock = (_lastPosition?.intraBlockOffset ?? 0) / 1000;
        chapterProgress =
            ((blockIndex + intraBlock) / currentChapter.blocks.length).clamp(
              0.0,
              1.0,
            );
      }
    }

    final readerStream = KeyedSubtree(
      key: const ValueKey('reader-stream'),
      child: SizedBox.expand(
        key: _viewportKey,
        child: RepaintBoundary(
          key: const ValueKey('reader-scroll-repaint-boundary'),
          child: _settings.layoutMode == ReaderLayoutMode.pages
              ? _buildHorizontalReader(foreground)
              : _buildVerticalReader(foreground),
        ),
      ),
    );

    return KeyboardListener(
      key: const ValueKey('reader-keyboard-navigation'),
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: readerBackground,
        body: Stack(
          children: [
            Positioned.fill(
              child: Semantics(
                label: _settings.layoutMode == ReaderLayoutMode.pages
                    ? '分页阅读区域'
                    : '滚动阅读区域',
                onIncrease: () =>
                    unawaited(_turnPage(ReaderLoadDirection.after)),
                onDecrease: () =>
                    unawaited(_turnPage(ReaderLoadDirection.before)),
                child: Listener(
                  key: const ValueKey('reader-center-tap-area'),
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _handlePointerDown,
                  onPointerUp: _handlePointerUp,
                  onPointerCancel: _handlePointerCancel,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      final expectedAxis =
                          _settings.layoutMode == ReaderLayoutMode.pages
                          ? Axis.horizontal
                          : Axis.vertical;
                      if (notification.metrics.axis != expectedAxis) {
                        return false;
                      }
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
                    child: _settings.textSelectionEnabled
                        ? SelectionArea(
                            key: const ValueKey('reader-selection-area'),
                            onSelectionChanged: _handleSelectionChanged,
                            child: readerStream,
                          )
                        : readerStream,
                  ),
                ),
              ),
            ),
            _ReaderTopChrome(
              visible: _chromeVisible,
              title: widget.novel.chineseTitle,
              chapterTitle: currentChapter?.chineseTitle ?? '',
              onBack: () => Navigator.maybePop(context),
              background: readerColors.chrome,
              foreground: foreground,
            ),
            _ReaderBottomChrome(
              visible: _chromeVisible,
              mode: _settings.readingMode,
              source: _settings.translationSource,
              bookmarked: currentBookmark,
              catalog: catalog,
              activeChapterIndex: currentCatalogIndex < 0
                  ? 0
                  : currentCatalogIndex,
              chapterProgress: chapterProgress,
              onChapterSelected: _openCatalogIndex,
              onCatalog: () => _runChromeAction(_showCatalog),
              onMode: () => _runChromeAction(_toggleMode),
              onSource: () => _runChromeAction(_showTranslationSources),
              onSettings: () => _runChromeAction(_showSettings),
              onBookmark: () => _runChromeAction(_toggleBookmark),
              background: readerColors.chrome,
              foreground: foreground,
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
      ),
    );
  }
}

class _ReaderHorizontalPage {
  const _ReaderHorizontalPage({
    required this.entries,
    required this.anchor,
    required this.anchorIntraBlockOffset,
  });

  final List<_ReaderHorizontalEntry> entries;
  final AlignedBlockItem? anchor;
  final int anchorIntraBlockOffset;
}

class _ReaderHorizontalEntry {
  const _ReaderHorizontalEntry({
    required this.readerItemIndex,
    this.fragment,
    this.scaleToFit = false,
  });

  final int readerItemIndex;
  final _ReaderTextFragment? fragment;
  final bool scaleToFit;
}

class _ReaderTextFragment {
  const _ReaderTextFragment({
    required this.index,
    required this.chinese,
    required this.japanese,
    required this.intraBlockOffset,
    required this.estimatedHeight,
  });

  final int index;
  final String? chinese;
  final String? japanese;
  final int intraBlockOffset;
  final double estimatedHeight;
}

class _ReaderHorizontalLocation {
  const _ReaderHorizontalLocation({
    required this.pageIndex,
    required this.intraBlockOffset,
  });

  final int pageIndex;
  final int intraBlockOffset;
}

class _VisibleReaderAnchor {
  const _VisibleReaderAnchor({
    required this.stableId,
    required this.intraBlockOffset,
    required this.viewportOffset,
  });

  final String stableId;
  final int intraBlockOffset;
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
            padding: EdgeInsets.fromLTRB(
              settings.pageMargin,
              42,
              settings.pageMargin,
              24,
            ),
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
                    fontFamily:
                        settings.fontFamily == ReaderFontFamily.systemSerif
                        ? 'serif'
                        : null,
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

bool _usesParallelColumns(ReaderSettings settings, double viewportWidth) {
  return viewportWidth >= 1000 &&
      settings.columnLayout != ReaderColumnLayout.singleColumn;
}

class _HorizontalAlignedBlockFragmentView extends StatelessWidget {
  const _HorizontalAlignedBlockFragmentView({
    required this.item,
    required this.fragment,
    required this.settings,
    required this.foreground,
    required this.bookmarked,
    super.key,
  });

  final AlignedBlockItem item;
  final _ReaderTextFragment fragment;
  final ReaderSettings settings;
  final Color foreground;
  final bool bookmarked;

  @override
  Widget build(BuildContext context) {
    final bodyWeight = settings.bodyBold ? FontWeight.w600 : FontWeight.w400;
    final bodyFamily = settings.fontFamily == ReaderFontFamily.systemSerif
        ? 'serif'
        : null;
    final hasTranslation =
        item.chapter.translationState(settings.translationSource) ==
            TranslationState.complete &&
        item.block.translationFor(settings.translationSource) != null;
    final chineseText = fragment.chinese == null
        ? null
        : Text(
            fragment.chinese!,
            key: ValueKey(
              'block-${item.block.id}-chinese-fragment-${fragment.index}',
            ),
            style: TextStyle(
              locale: const Locale('zh', 'CN'),
              color: foreground,
              fontSize: settings.chineseFontSize,
              height: settings.lineHeight,
              fontWeight: bodyWeight,
              fontFamily: bodyFamily,
              letterSpacing: 0.15,
            ),
          );
    final japaneseText = fragment.japanese == null
        ? null
        : Text(
            fragment.japanese!,
            key: ValueKey(
              'block-${item.block.id}-japanese-fragment-${fragment.index}',
            ),
            style: TextStyle(
              locale: const Locale('ja', 'JP'),
              color: foreground.withValues(
                alpha: hasTranslation ? settings.japaneseOpacity : 0.88,
              ),
              fontSize: hasTranslation
                  ? settings.japaneseFontSize
                  : settings.chineseFontSize * 0.92,
              height: settings.lineHeight,
              fontWeight: bodyWeight,
              fontFamily: bodyFamily,
            ),
          );
    final parallel =
        chineseText != null &&
        japaneseText != null &&
        _usesParallelColumns(settings, MediaQuery.sizeOf(context).width);
    final isDialogue = item.block.kind == AlignedBlockKind.dialogue;
    final semanticLabel = [
      if (bookmarked && fragment.intraBlockOffset == 0) '已加入书签',
      if (fragment.chinese != null) '中文：${fragment.chinese}',
      if (fragment.japanese != null) '日文：${fragment.japanese}',
    ].join('\n');
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: settings.readingWidth),
        child: Semantics(
          container: true,
          excludeSemantics: true,
          label: semanticLabel,
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  settings.pageMargin + (isDialogue ? 10 : 0),
                  9,
                  settings.pageMargin + (isDialogue ? 6 : 0),
                  settings.paragraphSpacing,
                ),
                child: parallel
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: chineseText),
                          const SizedBox(width: 28),
                          Expanded(child: japaneseText),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [?chineseText, ?japaneseText],
                      ),
              ),
              if (bookmarked && fragment.intraBlockOffset == 0)
                Positioned(
                  top: 8,
                  right: (settings.pageMargin * 0.25).clamp(4.0, 12.0),
                  child: Icon(
                    Icons.bookmark_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlignedBlockView extends StatefulWidget {
  const _AlignedBlockView({
    required this.item,
    required this.settings,
    required this.foreground,
    required this.bookmarked,
    required this.onMounted,
    required this.onUnmounted,
    super.key,
  });

  final AlignedBlockItem item;
  final ReaderSettings settings;
  final Color foreground;
  final bool bookmarked;
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
      if (widget.bookmarked) '已加入书签',
      if (translation != null) '中文：$translation',
      if (showJapanese) '日文：${widget.item.block.japanese}',
    ].join('\n');
    final bodyWeight = widget.settings.bodyBold
        ? FontWeight.w600
        : FontWeight.w400;
    final bodyFamily =
        widget.settings.fontFamily == ReaderFontFamily.systemSerif
        ? 'serif'
        : null;
    final chineseText = translation == null
        ? null
        : Text(
            translation,
            key: ValueKey('block-${widget.item.block.id}-chinese'),
            style: TextStyle(
              locale: const Locale('zh', 'CN'),
              color: widget.foreground,
              fontSize: widget.settings.chineseFontSize,
              height: widget.settings.lineHeight,
              fontWeight: bodyWeight,
              fontFamily: bodyFamily,
              letterSpacing: 0.15,
            ),
          );
    final japaneseText = !showJapanese
        ? null
        : Text(
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
              fontWeight: bodyWeight,
              fontFamily: bodyFamily,
            ),
          );
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final parallelColumns =
        chineseText != null &&
        japaneseText != null &&
        _usesParallelColumns(widget.settings, viewportWidth);

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.settings.readingWidth),
        child: Semantics(
          container: true,
          excludeSemantics: true,
          label: semanticLabel,
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.settings.pageMargin + (isDialogue ? 10 : 0),
                  9,
                  widget.settings.pageMargin + (isDialogue ? 6 : 0),
                  widget.settings.paragraphSpacing,
                ),
                child: parallelColumns
                    ? Row(
                        key: ValueKey(
                          'block-${widget.item.block.id}-parallel-columns',
                        ),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: chineseText),
                          const SizedBox(width: 28),
                          Expanded(child: japaneseText),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ?chineseText,
                          if (chineseText != null && japaneseText != null)
                            SizedBox(
                              height: widget.settings.chineseFontSize * 0.42,
                            ),
                          ?japaneseText,
                        ],
                      ),
              ),
              if (widget.bookmarked)
                Positioned(
                  key: ValueKey(
                    'block-${widget.item.block.id}-bookmark-marker',
                  ),
                  top: 8,
                  right: (widget.settings.pageMargin * 0.25).clamp(4.0, 12.0),
                  child: Icon(
                    Icons.bookmark_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
            ],
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

class _ReaderPaletteColors {
  const _ReaderPaletteColors({
    required this.background,
    required this.foreground,
    required this.chrome,
  });

  final Color background;
  final Color foreground;
  final Color chrome;

  static _ReaderPaletteColors resolve(
    ReaderPalette palette,
    Brightness systemBrightness,
  ) {
    final effective = palette == ReaderPalette.automatic
        ? systemBrightness == Brightness.dark
              ? ReaderPalette.dark
              : ReaderPalette.paper
        : palette;
    return switch (effective) {
      ReaderPalette.automatic => throw StateError('Palette was not resolved.'),
      ReaderPalette.paper => const _ReaderPaletteColors(
        background: Color(0xFFF5F2E8),
        foreground: Color(0xFF252925),
        chrome: Color(0xFFF9F7F0),
      ),
      ReaderPalette.sepia => const _ReaderPaletteColors(
        background: Color(0xFFF0E1C2),
        foreground: Color(0xFF3B2D20),
        chrome: Color(0xFFF5E8CF),
      ),
      ReaderPalette.lowLight => const _ReaderPaletteColors(
        background: Color(0xFF27302D),
        foreground: Color(0xFFD3D9D2),
        chrome: Color(0xFF303A36),
      ),
      ReaderPalette.dark => const _ReaderPaletteColors(
        background: Color(0xFF171A18),
        foreground: Color(0xFFE8ECE8),
        chrome: Color(0xFF202421),
      ),
      ReaderPalette.black => const _ReaderPaletteColors(
        background: Color(0xFF000000),
        foreground: Color(0xFFE8E8E8),
        chrome: Color(0xFF0D0D0D),
      ),
    };
  }
}

class _ReaderTopChrome extends StatelessWidget {
  const _ReaderTopChrome({
    required this.visible,
    required this.title,
    required this.chapterTitle,
    required this.onBack,
    required this.background,
    required this.foreground,
  });

  final bool visible;
  final String title;
  final String chapterTitle;
  final VoidCallback onBack;
  final Color background;
  final Color foreground;

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
              color: background.withValues(alpha: 0.97),
              child: IconTheme(
                data: IconThemeData(color: foreground),
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
                                ).copyWith(color: foreground),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                chapterTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: foreground.withValues(alpha: 0.68),
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
      ),
    );
  }
}

class _ReaderBottomChrome extends StatefulWidget {
  const _ReaderBottomChrome({
    required this.visible,
    required this.mode,
    required this.source,
    required this.bookmarked,
    required this.catalog,
    required this.activeChapterIndex,
    required this.chapterProgress,
    required this.onChapterSelected,
    required this.background,
    required this.foreground,
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
  final List<ReaderChapterCatalogEntry> catalog;
  final int activeChapterIndex;
  final double chapterProgress;
  final ValueChanged<int> onChapterSelected;
  final Color background;
  final Color foreground;
  final VoidCallback onCatalog;
  final VoidCallback onMode;
  final VoidCallback onSource;
  final VoidCallback onSettings;
  final VoidCallback onBookmark;

  @override
  State<_ReaderBottomChrome> createState() => _ReaderBottomChromeState();
}

class _ReaderBottomChromeState extends State<_ReaderBottomChrome> {
  double? _previewIndex;

  @override
  void didUpdateWidget(_ReaderBottomChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeChapterIndex != widget.activeChapterIndex ||
        oldWidget.catalog.length != widget.catalog.length) {
      _previewIndex = null;
    }
  }

  int get _displayIndex {
    if (widget.catalog.isEmpty) return 0;
    return (_previewIndex?.round() ?? widget.activeChapterIndex).clamp(
      0,
      widget.catalog.length - 1,
    );
  }

  String get _progressLabel {
    if (widget.catalog.isEmpty) return '暂无章节';
    if (_previewIndex != null) {
      final chapter = widget.catalog[_displayIndex];
      return '第 ${_displayIndex + 1} / ${widget.catalog.length} 章 · '
          '${chapter.chineseTitle}';
    }
    return '第 ${widget.activeChapterIndex + 1} / ${widget.catalog.length} 章 · '
        '本章 ${(widget.chapterProgress * 100).round()}%';
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          offset: widget.visible ? Offset.zero : const Offset(0, 1),
          child: AnimatedOpacity(
            key: const ValueKey('reader-bottom-chrome'),
            duration: const Duration(milliseconds: 140),
            opacity: widget.visible ? 1 : 0,
            child: Material(
              elevation: 4,
              color: widget.background.withValues(alpha: 0.97),
              child: IconTheme(
                data: IconThemeData(color: widget.foreground),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: widget.foreground),
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 128,
                      child: Column(
                        children: [
                          SizedBox(
                            height: 52,
                            child: Row(
                              children: [
                                IconButton(
                                  key: const ValueKey(
                                    'previous-chapter-button',
                                  ),
                                  tooltip: '上一章',
                                  onPressed:
                                      widget.catalog.isNotEmpty &&
                                          _displayIndex > 0
                                      ? () => widget.onChapterSelected(
                                          _displayIndex - 1,
                                        )
                                      : null,
                                  icon: const Icon(Icons.skip_previous_rounded),
                                ),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Semantics(
                                        key: const ValueKey(
                                          'reader-progress-label',
                                        ),
                                        liveRegion: true,
                                        label: _progressLabel,
                                        child: Text(
                                          _progressLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      ),
                                      if (widget.catalog.length > 1)
                                        SizedBox(
                                          height: 24,
                                          child: SliderTheme(
                                            data: SliderTheme.of(context).copyWith(
                                              trackHeight: 2,
                                              thumbShape:
                                                  const RoundSliderThumbShape(
                                                    enabledThumbRadius: 6,
                                                  ),
                                              overlayShape:
                                                  const RoundSliderOverlayShape(
                                                    overlayRadius: 14,
                                                  ),
                                            ),
                                            child: Slider(
                                              key: const ValueKey(
                                                'reader-chapter-scrubber',
                                              ),
                                              value:
                                                  _previewIndex ??
                                                  widget.activeChapterIndex
                                                      .toDouble(),
                                              min: 0,
                                              max: (widget.catalog.length - 1)
                                                  .toDouble(),
                                              divisions:
                                                  widget.catalog.length - 1,
                                              label: widget
                                                  .catalog[_displayIndex]
                                                  .chineseTitle,
                                              onChanged: (value) {
                                                setState(
                                                  () => _previewIndex = value,
                                                );
                                              },
                                              onChangeEnd: (value) {
                                                final target = value.round();
                                                setState(
                                                  () => _previewIndex = null,
                                                );
                                                if (target !=
                                                    widget.activeChapterIndex) {
                                                  widget.onChapterSelected(
                                                    target,
                                                  );
                                                }
                                              },
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  key: const ValueKey('next-chapter-button'),
                                  tooltip: '下一章',
                                  onPressed:
                                      widget.catalog.isNotEmpty &&
                                          _displayIndex <
                                              widget.catalog.length - 1
                                      ? () => widget.onChapterSelected(
                                          _displayIndex + 1,
                                        )
                                      : null,
                                  icon: const Icon(Icons.skip_next_rounded),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Row(
                              children: [
                                _ChromeAction(
                                  key: const ValueKey('catalog-button'),
                                  icon: Icons.format_list_numbered_rounded,
                                  label: '目录',
                                  onTap: widget.onCatalog,
                                ),
                                _ChromeAction(
                                  key: const ValueKey('reading-mode-button'),
                                  icon: Icons.translate_rounded,
                                  label:
                                      widget.mode == ReadingMode.chineseJapanese
                                      ? '中日'
                                      : '中文',
                                  onTap: widget.onMode,
                                ),
                                _ChromeAction(
                                  key: const ValueKey(
                                    'translation-source-button',
                                  ),
                                  icon: Icons.hub_outlined,
                                  label: widget.source.label,
                                  onTap: widget.onSource,
                                ),
                                _ChromeAction(
                                  key: const ValueKey('reader-settings-button'),
                                  icon: Icons.text_fields_rounded,
                                  label: '样式',
                                  onTap: widget.onSettings,
                                ),
                                _ChromeAction(
                                  key: const ValueKey('bookmark-button'),
                                  icon: widget.bookmarked
                                      ? Icons.bookmark_rounded
                                      : Icons.bookmark_border_rounded,
                                  label: widget.bookmarked ? '已书签' : '书签',
                                  onTap: widget.onBookmark,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _ReaderNavigationTarget {
  const _ReaderNavigationTarget({required this.chapter, this.position});

  final ReaderChapterCatalogEntry chapter;
  final ReadingPosition? position;
}

class _ChapterCatalogSheet extends StatefulWidget {
  const _ChapterCatalogSheet({
    required this.catalog,
    required this.activeChapterId,
    required this.loadedChapterIds,
    required this.loadedChapters,
    required this.bookmarks,
    required this.settings,
    required this.onBookmarkRemoved,
  });

  final List<ReaderChapterCatalogEntry> catalog;
  final String? activeChapterId;
  final Set<String> loadedChapterIds;
  final List<NovelChapter> loadedChapters;
  final List<ReadingPosition> bookmarks;
  final ReaderSettings settings;
  final ValueChanged<ReadingPosition> onBookmarkRemoved;

  @override
  State<_ChapterCatalogSheet> createState() => _ChapterCatalogSheetState();
}

class _ChapterCatalogSheetState extends State<_ChapterCatalogSheet> {
  late final List<ReadingPosition> _bookmarks;

  @override
  void initState() {
    super.initState();
    _bookmarks = List.of(widget.bookmarks);
  }

  List<({String? title, ReaderChapterCatalogEntry? chapter})> get _rows {
    final grouped = widget.catalog.any(
      (entry) => entry.sectionTitle != null && entry.sectionTitle!.isNotEmpty,
    );
    if (!grouped) {
      return [
        for (final chapter in widget.catalog) (title: null, chapter: chapter),
      ];
    }
    final rows = <({String? title, ReaderChapterCatalogEntry? chapter})>[];
    String? current;
    for (final chapter in widget.catalog) {
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

  List<
    ({
      ReadingPosition position,
      ReaderChapterCatalogEntry chapter,
      String excerpt,
    })
  >
  get _bookmarkRows {
    final chaptersById = {
      for (final chapter in widget.loadedChapters) chapter.id: chapter,
    };
    final catalogById = {
      for (final chapter in widget.catalog) chapter.id: chapter,
    };
    return [
      for (final position in _bookmarks)
        if (catalogById[position.chapterId] case final catalogChapter?)
          (
            position: position,
            chapter: catalogChapter,
            excerpt: _bookmarkExcerpt(
              chaptersById[position.chapterId],
              position,
            ),
          ),
    ];
  }

  String _bookmarkExcerpt(NovelChapter? chapter, ReadingPosition position) {
    final block = chapter?.blocks
        .where((block) => block.id == position.blockId)
        .firstOrNull;
    if (block == null) return '打开后加载已保存段落';
    final translation =
        chapter!.translationState(widget.settings.translationSource) ==
            TranslationState.complete
        ? block.translationFor(widget.settings.translationSource)
        : null;
    final text = (translation ?? block.japanese).replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    return text.length <= 72 ? text : '${text.substring(0, 72)}…';
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.76,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '阅读导航',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text('${widget.catalog.length} 章 · ${_bookmarks.length} 书签'),
                ],
              ),
            ),
            const TabBar(
              tabs: [
                Tab(key: ValueKey('reader-navigation-chapters'), text: '目录'),
                Tab(key: ValueKey('reader-navigation-bookmarks'), text: '书签'),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  ListView.builder(
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
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        );
                      }
                      final active = chapter.id == widget.activeChapterId;
                      final loaded = widget.loadedChapterIds.contains(
                        chapter.id,
                      );
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
                        onTap: () => Navigator.pop(
                          context,
                          _ReaderNavigationTarget(chapter: chapter),
                        ),
                      );
                    },
                  ),
                  _bookmarkRows.isEmpty
                      ? const Center(
                          child: Text(
                            '还没有书签',
                            key: ValueKey('reader-bookmarks-empty'),
                          ),
                        )
                      : ListView.builder(
                          key: const ValueKey('reader-bookmarks-list'),
                          itemCount: _bookmarkRows.length,
                          itemBuilder: (context, index) {
                            final bookmark = _bookmarkRows[index];
                            return ListTile(
                              key: ValueKey(
                                'reader-bookmark-${bookmark.position.blockId}',
                              ),
                              leading: const Icon(Icons.bookmark_rounded),
                              title: Text(bookmark.chapter.chineseTitle),
                              subtitle: Text(
                                bookmark.excerpt,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                key: ValueKey(
                                  'remove-reader-bookmark-'
                                  '${bookmark.position.blockId}',
                                ),
                                tooltip: '删除书签',
                                onPressed: () {
                                  setState(() {
                                    _bookmarks.removeWhere(
                                      (position) =>
                                          position.blockId ==
                                          bookmark.position.blockId,
                                    );
                                  });
                                  widget.onBookmarkRemoved(bookmark.position);
                                },
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                              onTap: () => Navigator.pop(
                                context,
                                _ReaderNavigationTarget(
                                  chapter: bookmark.chapter,
                                  position: bookmark.position,
                                ),
                              ),
                            );
                          },
                        ),
                ],
              ),
            ),
          ],
        ),
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
  const _SettingsResult({required this.settings});

  final ReaderSettings settings;
}

class _ReaderSettingsSheet extends StatefulWidget {
  const _ReaderSettingsSheet({required this.settings, required this.onPreview});

  final ReaderSettings settings;
  final ValueChanged<ReaderSettings> onPreview;

  @override
  State<_ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<_ReaderSettingsSheet> {
  late ReaderSettings _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.settings;
  }

  void _update(ReaderSettings settings) {
    setState(() => _draft = settings);
    widget.onPreview(settings);
  }

  void _resetAppearance() {
    _update(
      _draft.copyWith(
        palette: ReaderPalette.automatic,
        fontFamily: ReaderFontFamily.systemSans,
        bodyBold: false,
        chineseFontSize: 22,
        japaneseFontSize: 16,
        lineHeight: 1.8,
        paragraphSpacing: 15,
        japaneseOpacity: 0.56,
        pageMargin: 24,
        readingWidth: 720,
        columnLayout: ReaderColumnLayout.automatic,
        orientationPreference: ReaderOrientationPreference.followDevice,
      ),
    );
  }

  String _paletteLabel(ReaderPalette palette) {
    return switch (palette) {
      ReaderPalette.automatic => '自动',
      ReaderPalette.paper => '纸张',
      ReaderPalette.sepia => '棕褐',
      ReaderPalette.lowLight => '低光',
      ReaderPalette.dark => '深色',
      ReaderPalette.black => '纯黑',
    };
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '阅读样式',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  key: const ValueKey('settings-reset-appearance'),
                  onPressed: _resetAppearance,
                  child: const Text('重置'),
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
                    _update(_draft.copyWith(readingMode: selection.single));
                  },
                ),
                const SizedBox(height: 22),
                _SectionLabel('布局'),
                const SizedBox(height: 10),
                SegmentedButton<ReaderLayoutMode>(
                  key: const ValueKey('settings-layout-mode'),
                  segments: const [
                    ButtonSegment(
                      value: ReaderLayoutMode.scroll,
                      icon: Icon(Icons.swap_vert_rounded),
                      label: Text('滚动'),
                    ),
                    ButtonSegment(
                      value: ReaderLayoutMode.pages,
                      icon: Icon(Icons.menu_book_rounded),
                      label: Text('翻页'),
                    ),
                  ],
                  selected: {_draft.layoutMode},
                  onSelectionChanged: (selection) {
                    _update(_draft.copyWith(layoutMode: selection.single));
                  },
                ),
                const SizedBox(height: 22),
                _SectionLabel('交互'),
                SwitchListTile(
                  key: const ValueKey('settings-text-selection'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许选择文本'),
                  subtitle: const Text('关闭后，长按或拖动不会选中文字'),
                  value: _draft.textSelectionEnabled,
                  onChanged: (value) {
                    _update(_draft.copyWith(textSelectionEnabled: value));
                  },
                ),
                SwitchListTile(
                  key: const ValueKey('settings-tap-page-turn'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('点击两侧翻页'),
                  subtitle: const Text('关闭后仍可滑动、拖动或使用键盘翻页'),
                  value: _draft.tapPageTurnEnabled,
                  onChanged: (value) {
                    _update(_draft.copyWith(tapPageTurnEnabled: value));
                  },
                ),
                const SizedBox(height: 10),
                _SectionLabel('页面配色'),
                const SizedBox(height: 10),
                Wrap(
                  key: const ValueKey('settings-reader-palette'),
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final palette in ReaderPalette.values)
                      ChoiceChip(
                        key: ValueKey('reader-palette-${palette.name}'),
                        label: Text(_paletteLabel(palette)),
                        selected: _draft.palette == palette,
                        onSelected: (_) {
                          _update(_draft.copyWith(palette: palette));
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 22),
                _SectionLabel('字体'),
                const SizedBox(height: 10),
                SegmentedButton<ReaderFontFamily>(
                  key: const ValueKey('settings-font-family'),
                  segments: const [
                    ButtonSegment(
                      value: ReaderFontFamily.systemSans,
                      label: Text('无衬线'),
                    ),
                    ButtonSegment(
                      value: ReaderFontFamily.systemSerif,
                      label: Text('衬线'),
                    ),
                  ],
                  selected: {_draft.fontFamily},
                  onSelectionChanged: (selection) {
                    _update(_draft.copyWith(fontFamily: selection.single));
                  },
                ),
                SwitchListTile(
                  key: const ValueKey('settings-body-bold'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('加粗正文'),
                  value: _draft.bodyBold,
                  onChanged: (value) {
                    _update(_draft.copyWith(bodyBold: value));
                  },
                ),
                _ReaderSlider(
                  label: '中文字号',
                  valueLabel: _draft.chineseFontSize.round().toString(),
                  value: _draft.chineseFontSize,
                  min: 17,
                  max: 30,
                  divisions: 13,
                  onChanged: (value) {
                    _update(_draft.copyWith(chineseFontSize: value));
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
                    _update(_draft.copyWith(japaneseFontSize: value));
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
                    _update(_draft.copyWith(lineHeight: value));
                  },
                ),
                _ReaderSlider(
                  label: '段落间距',
                  valueLabel: _draft.paragraphSpacing.round().toString(),
                  value: _draft.paragraphSpacing,
                  min: 8,
                  max: 28,
                  divisions: 10,
                  onChanged: (value) {
                    _update(_draft.copyWith(paragraphSpacing: value));
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
                    _update(_draft.copyWith(japaneseOpacity: value));
                  },
                ),
                _ReaderSlider(
                  label: '页面边距',
                  valueLabel: _draft.pageMargin.round().toString(),
                  value: _draft.pageMargin,
                  min: 12,
                  max: 48,
                  divisions: 12,
                  onChanged: (value) {
                    _update(_draft.copyWith(pageMargin: value));
                  },
                ),
                _ReaderSlider(
                  label: '正文宽度',
                  valueLabel: '${_draft.readingWidth.round()} px',
                  value: _draft.readingWidth,
                  min: 480,
                  max: 1200,
                  divisions: 24,
                  onChanged: (value) {
                    _update(_draft.copyWith(readingWidth: value));
                  },
                ),
                const SizedBox(height: 10),
                _SectionLabel('宽屏对照'),
                const SizedBox(height: 10),
                SegmentedButton<ReaderColumnLayout>(
                  key: const ValueKey('settings-column-layout'),
                  segments: const [
                    ButtonSegment(
                      value: ReaderColumnLayout.automatic,
                      label: Text('自动'),
                    ),
                    ButtonSegment(
                      value: ReaderColumnLayout.singleColumn,
                      label: Text('单栏'),
                    ),
                    ButtonSegment(
                      value: ReaderColumnLayout.twoColumns,
                      label: Text('对照双栏'),
                    ),
                  ],
                  selected: {_draft.columnLayout},
                  onSelectionChanged: (selection) {
                    _update(_draft.copyWith(columnLayout: selection.single));
                  },
                ),
                const SizedBox(height: 22),
                _SectionLabel('屏幕方向'),
                const SizedBox(height: 10),
                SegmentedButton<ReaderOrientationPreference>(
                  key: const ValueKey('settings-orientation'),
                  segments: const [
                    ButtonSegment(
                      value: ReaderOrientationPreference.followDevice,
                      label: Text('跟随'),
                    ),
                    ButtonSegment(
                      value: ReaderOrientationPreference.portrait,
                      label: Text('竖屏'),
                    ),
                    ButtonSegment(
                      value: ReaderOrientationPreference.landscape,
                      label: Text('横屏'),
                    ),
                  ],
                  selected: {_draft.orientationPreference},
                  onSelectionChanged: (selection) {
                    _update(
                      _draft.copyWith(orientationPreference: selection.single),
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
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('settings-cancel'),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('settings-apply'),
                      onPressed: () => Navigator.pop(
                        context,
                        _SettingsResult(settings: _draft),
                      ),
                      child: const Text('完成'),
                    ),
                  ),
                ],
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
