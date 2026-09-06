import 'package:flutter/material.dart';

import '../../core/model/reader_models.dart';
import 'reader_pagination.dart';

class ReaderAvailabilityBoundary extends StatelessWidget {
  const ReaderAvailabilityBoundary({
    super.key,
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

class ReaderCatalogLoadOverlay extends StatelessWidget {
  const ReaderCatalogLoadOverlay({
    super.key,
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

class ReaderChapterBoundary extends StatelessWidget {
  const ReaderChapterBoundary({
    super.key,
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

class ReaderHorizontalBlockFragmentView extends StatelessWidget {
  const ReaderHorizontalBlockFragmentView({
    required this.item,
    required this.fragment,
    required this.settings,
    required this.foreground,
    required this.bookmarked,
    super.key,
  });

  final AlignedBlockItem item;
  final ReaderTextFragment fragment;
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
        usesReaderParallelColumns(settings, MediaQuery.sizeOf(context).width);
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

class ReaderAlignedBlockView extends StatefulWidget {
  const ReaderAlignedBlockView({
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
  State<ReaderAlignedBlockView> createState() => _AlignedBlockViewState();
}

class _AlignedBlockViewState extends State<ReaderAlignedBlockView> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onMounted(context);
  }

  @override
  void didUpdateWidget(ReaderAlignedBlockView oldWidget) {
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
        usesReaderParallelColumns(widget.settings, viewportWidth);

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

class ReaderSkeleton extends StatelessWidget {
  const ReaderSkeleton({super.key});

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
