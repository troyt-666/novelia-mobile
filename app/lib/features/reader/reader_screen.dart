import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show ScrollCacheExtent, ScrollDirection, SelectedContent;
import 'package:flutter/services.dart';

import '../../core/model/reader_models.dart';
import 'reader_body.dart';
import 'reader_controls.dart';
import 'reader_pagination.dart';

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
  static const _verticalCenterKey = ValueKey('reader-scroll-center');

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
  String? _verticalCenterId;
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
  bool _waitingForUserScrollAfterJump = true;
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
  ReaderPagination? _pagination;
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
    _verticalCenterId = _items.firstOrNull?.stableId;
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
    final position = _waitingForUserScrollAfterJump
        ? _lastPosition
        : (_captureAnchor(notify: false, updateUi: false) == null
              ? null
              : _lastPosition);
    if (position == null) return;
    final generation = ++_metricsRelayoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _metricsRelayoutGeneration) return;
      _waitingForUserScrollAfterJump = true;
      _preservingDynamicAnchor = true;
      await _jumpToStableId(
        'block:${position.blockId}',
        intraBlockOffset: position.intraBlockOffset,
      );
      if (mounted && generation == _metricsRelayoutGeneration) {
        _preservingDynamicAnchor = false;
      }
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
      } else if (_verticalScrollController.hasClients) {
        _verticalScrollController.jumpTo(
          _verticalScrollController.position.minScrollExtent,
        );
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
      final page = _pagination?.pageForStableId(stableId, intraBlockOffset);
      if (page != null && _pageController.hasClients) {
        _pageController.jumpToPage(page);
        await WidgetsBinding.instance.endOfFrame;
      }
      return;
    }

    var targetContext = _mountedContextFor(stableId);
    if (targetContext == null) {
      _verticalScrollController.jumpTo(0);
      setState(() {
        _verticalCenterId = stableId;
        _windowStart = targetIndex;
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
      if (_settings.layoutMode == ReaderLayoutMode.pages) {
        final addedExtent = controller.position.maxScrollExtent - oldMaxExtent;
        final target = (oldPixels + addedExtent).clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        );
        controller.jumpTo(target);
      }
      _adjustingWindow = false;
    });
  }

  void _handleScrollMetrics(
    ScrollMetrics metrics, {
    required bool movingTowardBefore,
    required bool movingTowardAfter,
  }) {
    if (_restoring || _preservingDynamicAnchor) return;

    if (metrics.extentBefore > _boundaryRearmExtent) {
      _beforeRequestArmed = true;
    }
    if (metrics.extentAfter > _boundaryRearmExtent) {
      _afterRequestArmed = true;
    }

    if (movingTowardBefore && metrics.extentBefore < _boundaryTriggerExtent) {
      if (_windowStart > 0) {
        _extendWindowBackward();
      } else if (_beforeRequestArmed) {
        _beforeRequestArmed = false;
        unawaited(_requestAdjacent(ReaderLoadDirection.before));
      }
    }
    if (movingTowardAfter && metrics.extentAfter < _boundaryTriggerExtent) {
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
    if (_settings.layoutMode == ReaderLayoutMode.scroll) {
      final firstId = _items[_windowStart].stableId;
      final lastId = _items[_windowEnd - 1].stableId;
      setState(() {
        _mergeLoadedChapters(incoming);
        _windowStart = (_itemIndices[firstId]! - _windowLeadInItems).clamp(
          0,
          _items.length,
        );
        _windowEnd = _itemIndices[lastId]! + 1;
        _beforeBoundary = beforeStatus;
        _beforeLoading = false;
        _beforeLoadError = null;
        _beforeRequestArmed = beforeStatus == ReaderBoundaryStatus.loadable;
      });
      return;
    }
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
    final pages = _pagination?.pages ?? const [];
    if (pages.isEmpty || !_pageController.hasClients) return null;
    final pageIndex = (_pageController.page?.round() ?? 0).clamp(
      0,
      pages.length - 1,
    );
    final page = pages[pageIndex];
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
      _waitingForUserScrollAfterJump = true;
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
    _waitingForUserScrollAfterJump = false;
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

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && event.scrollDelta != Offset.zero) {
      _waitingForUserScrollAfterJump = false;
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
    _waitingForUserScrollAfterJump = false;
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
    final target = await showModalBottomSheet<ReaderNavigationTarget>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ReaderChapterCatalogSheet(
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
      final navigationGeneration = ++_windowGeneration;
      setState(() {
        _beforeLoading = false;
        _afterLoading = false;
        _beforeLoadError = null;
        _afterLoadError = null;
        _catalogLoadError = null;
        _catalogRetryEntry = null;
      });
      await _jumpToLoadedPosition(
        loadedChapter,
        position,
        navigationGeneration: navigationGeneration,
      );
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
        _verticalCenterId = _items[targetIndex].stableId;
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
      if (!mounted || requestGeneration != _windowGeneration) return;
      await _jumpToLoadedPosition(
        selected,
        position,
        navigationGeneration: requestGeneration,
      );
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
    ReadingPosition? requested, {
    required int navigationGeneration,
  }) async {
    setState(() {
      _restoring = true;
      _waitingForUserScrollAfterJump = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || navigationGeneration != _windowGeneration) return;
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
      alignment: requestedBlock == null ? 0.16 : 0,
    );
    if (!mounted || navigationGeneration != _windowGeneration) return;
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
      builder: (context) => ReaderTranslationSourceSheet(
        selectedSource: _settings.translationSource,
      ),
    );
    if (source != null && source != _settings.translationSource && mounted) {
      await _applySettings(_settings.copyWith(translationSource: source));
    }
  }

  Future<void> _showSettings() async {
    final originalSettings = _settings;
    final result = await showModalBottomSheet<ReaderSettings>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ReaderSettingsSheet(
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
    await _applySettings(result);
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

  Widget _buildReaderItem(BuildContext context, int index, Color foreground) {
    final showBeforeBoundary = _windowStart == 0;
    if (showBeforeBoundary && index == 0) {
      return ReaderAvailabilityBoundary(
        direction: ReaderLoadDirection.before,
        status: _beforeBoundary,
        loading: _beforeLoading,
        error: _beforeLoadError,
        onRetry: () => unawaited(_requestAdjacent(ReaderLoadDirection.before)),
      );
    }
    final streamIndex = index - (showBeforeBoundary ? 1 : 0);
    if (streamIndex >= _windowEnd - _windowStart) {
      return ReaderAvailabilityBoundary(
        direction: ReaderLoadDirection.after,
        status: _afterBoundary,
        loading: _afterLoading,
        error: _afterLoadError,
        onRetry: () => unawaited(_requestAdjacent(ReaderLoadDirection.after)),
      );
    }
    final item = _items[_windowStart + streamIndex];
    return switch (item) {
      ChapterBoundaryItem() => ReaderChapterBoundary(
        item: item,
        itemKey: _itemKeys[item.stableId]!,
        settings: _settings,
        foreground: foreground,
      ),
      AlignedBlockItem() => ReaderAlignedBlockView(
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

  Widget _buildVerticalReader(Color foreground) {
    final centerStreamIndex = (_itemIndices[_verticalCenterId] ?? _windowStart)
        .clamp(_windowStart, _windowEnd);
    _verticalCenterId = _items.elementAtOrNull(centerStreamIndex)?.stableId;
    final centerIndex =
        centerStreamIndex - _windowStart + (_windowStart == 0 ? 1 : 0);
    final topPadding = MediaQuery.paddingOf(context).top + 88;
    return LayoutBuilder(
      builder: (context, constraints) => CustomScrollView(
        controller: _verticalScrollController,
        physics: const ClampingScrollPhysics(),
        scrollCacheExtent: const ScrollCacheExtent.viewport(2),
        // Keep the same semantic origin while earlier items grow upwards.
        // A lazy list's estimated maxScrollExtent is not a prepend distance.
        center: _verticalCenterKey,
        anchor: (topPadding / constraints.maxHeight).clamp(0.0, 1.0),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(top: topPadding),
            sliver: SliverList.builder(
              addAutomaticKeepAlives: false,
              addSemanticIndexes: false,
              itemCount: centerIndex,
              itemBuilder: (context, index) => _buildReaderItem(
                context,
                centerIndex - index - 1,
                foreground,
              ),
            ),
          ),
          SliverPadding(
            key: _verticalCenterKey,
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 164,
            ),
            sliver: SliverList.builder(
              addAutomaticKeepAlives: false,
              addSemanticIndexes: false,
              itemCount: _readerItemCount - centerIndex,
              itemBuilder: (context, index) =>
                  _buildReaderItem(context, centerIndex + index, foreground),
            ),
          ),
        ],
      ),
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
        final pagination = ReaderPagination.compose(
          items: [
            for (var index = 0; index < _readerItemCount; index++)
              if (_streamIndexForReaderItem(index) case final streamIndex?)
                _items[streamIndex]
              else
                null,
          ],
          settings: _settings,
          textScaler: MediaQuery.textScalerOf(context),
          viewportWidth: constraints.maxWidth,
          availableHeight: availableHeight,
        );
        _pagination = pagination;
        final pages = pagination.pages;
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
    ReaderHorizontalEntry entry,
    Color foreground,
    double viewportWidth,
    double availableHeight,
  ) {
    final fragment = entry.fragment;
    if (fragment != null) {
      final streamIndex = _streamIndexForReaderItem(entry.readerItemIndex);
      final item = streamIndex == null ? null : _items[streamIndex];
      if (item is AlignedBlockItem) {
        return ReaderHorizontalBlockFragmentView(
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
    final readerColors = ReaderPaletteColors.resolve(
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
                  onPointerSignal: _handlePointerSignal,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      final expectedAxis =
                          _settings.layoutMode == ReaderLayoutMode.pages
                          ? Axis.horizontal
                          : Axis.vertical;
                      if (notification.metrics.axis != expectedAxis) {
                        return false;
                      }
                      // A restored or catalog-selected window intentionally
                      // starts close to its semantic anchor. Do not prepend
                      // older items merely because the reader continues
                      // forward from that position.
                      final movingTowardBefore = switch (notification) {
                        ScrollUpdateNotification(:final scrollDelta) =>
                          (scrollDelta ?? 0) < 0,
                        OverscrollNotification(:final overscroll) =>
                          overscroll < 0,
                        _ => false,
                      };
                      final movingTowardAfter = switch (notification) {
                        ScrollUpdateNotification(:final scrollDelta) =>
                          (scrollDelta ?? 0) > 0,
                        OverscrollNotification(:final overscroll) =>
                          overscroll > 0,
                        _ => false,
                      };
                      _handleScrollMetrics(
                        notification.metrics,
                        movingTowardBefore: movingTowardBefore,
                        movingTowardAfter: movingTowardAfter,
                      );
                      _handleReaderScroll(notification);
                      if (!_restoring &&
                          !_waitingForUserScrollAfterJump &&
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
            ReaderTopChrome(
              visible: _chromeVisible,
              title: widget.novel.chineseTitle,
              chapterTitle: currentChapter?.chineseTitle ?? '',
              onBack: () => Navigator.maybePop(context),
              background: readerColors.chrome,
              foreground: foreground,
            ),
            ReaderBottomChrome(
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
              ReaderCatalogLoadOverlay(
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
                  child: const ReaderSkeleton(),
                ),
              ),
          ],
        ),
      ),
    );
  }
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
