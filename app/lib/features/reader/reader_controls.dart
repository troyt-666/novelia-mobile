import 'package:flutter/material.dart';

import '../../core/model/reader_models.dart';

class ReaderPaletteColors {
  const ReaderPaletteColors({
    required this.background,
    required this.foreground,
    required this.chrome,
  });

  final Color background;
  final Color foreground;
  final Color chrome;

  static ReaderPaletteColors resolve(
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
      ReaderPalette.paper => const ReaderPaletteColors(
        background: Color(0xFFF5F2E8),
        foreground: Color(0xFF252925),
        chrome: Color(0xFFF9F7F0),
      ),
      ReaderPalette.sepia => const ReaderPaletteColors(
        background: Color(0xFFF0E1C2),
        foreground: Color(0xFF3B2D20),
        chrome: Color(0xFFF5E8CF),
      ),
      ReaderPalette.lowLight => const ReaderPaletteColors(
        background: Color(0xFF27302D),
        foreground: Color(0xFFD3D9D2),
        chrome: Color(0xFF303A36),
      ),
      ReaderPalette.dark => const ReaderPaletteColors(
        background: Color(0xFF171A18),
        foreground: Color(0xFFE8ECE8),
        chrome: Color(0xFF202421),
      ),
      ReaderPalette.black => const ReaderPaletteColors(
        background: Color(0xFF000000),
        foreground: Color(0xFFE8E8E8),
        chrome: Color(0xFF0D0D0D),
      ),
    };
  }
}

class ReaderTopChrome extends StatelessWidget {
  const ReaderTopChrome({
    super.key,
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

class ReaderBottomChrome extends StatefulWidget {
  const ReaderBottomChrome({
    super.key,
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
  State<ReaderBottomChrome> createState() => _ReaderBottomChromeState();
}

class _ReaderBottomChromeState extends State<ReaderBottomChrome> {
  double? _previewIndex;

  @override
  void didUpdateWidget(ReaderBottomChrome oldWidget) {
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

class ReaderNavigationTarget {
  const ReaderNavigationTarget({required this.chapter, this.position});

  final ReaderChapterCatalogEntry chapter;
  final ReadingPosition? position;
}

class ReaderChapterCatalogSheet extends StatefulWidget {
  const ReaderChapterCatalogSheet({
    super.key,
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
  State<ReaderChapterCatalogSheet> createState() => _ChapterCatalogSheetState();
}

class _ChapterCatalogSheetState extends State<ReaderChapterCatalogSheet> {
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
                          ReaderNavigationTarget(chapter: chapter),
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
                                ReaderNavigationTarget(
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

class ReaderTranslationSourceSheet extends StatelessWidget {
  const ReaderTranslationSourceSheet({super.key, required this.selectedSource});

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

class ReaderSettingsSheet extends StatefulWidget {
  const ReaderSettingsSheet({
    super.key,
    required this.settings,
    required this.onPreview,
  });

  final ReaderSettings settings;
  final ValueChanged<ReaderSettings> onPreview;

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
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
                      onPressed: () => Navigator.pop(context, _draft),
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
