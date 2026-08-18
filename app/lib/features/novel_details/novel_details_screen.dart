import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/model/reader_models.dart';
import '../discover/catalog_card.dart';
import '../discover/catalog_models.dart';

class NovelDetailsScreen extends StatefulWidget {
  const NovelDetailsScreen({
    required this.novel,
    required this.onOpenReader,
    this.onFavorite,
    this.onDownload,
    this.onOpenOriginal,
    this.onAuthorSelected,
    this.onTagSelected,
    this.commentPageLoader,
    this.commentsPerPage = 2,
    super.key,
  });

  final CatalogNovel novel;
  final ValueChanged<NovelChapter?> onOpenReader;
  final VoidCallback? onFavorite;
  final FutureOr<void> Function()? onDownload;
  final FutureOr<void> Function()? onOpenOriginal;
  final ValueChanged<String>? onAuthorSelected;
  final ValueChanged<String>? onTagSelected;
  final NovelCommentPageLoader? commentPageLoader;
  final int commentsPerPage;

  @override
  State<NovelDetailsScreen> createState() => _NovelDetailsScreenState();
}

class _NovelDetailsScreenState extends State<NovelDetailsScreen> {
  bool _chaptersExpanded = false;
  bool _chaptersReversed = false;
  int _commentPage = 0;
  NovelCommentPage? _loadedCommentPage;
  Object? _commentError;
  bool _commentsLoading = false;
  int _commentRequestGeneration = 0;
  int _requestedCommentPage = 1;
  bool _downloadStarting = false;
  bool _openingOriginal = false;

  bool get _usesRemoteComments => widget.commentPageLoader != null;

  @override
  void initState() {
    super.initState();
    if (_usesRemoteComments) {
      _commentsLoading = true;
      unawaited(_loadCommentPage(1, announceLoading: false));
    }
  }

  int get _commentPageCount {
    if (_usesRemoteComments) return _loadedCommentPage?.totalPages ?? 0;
    if (widget.novel.comments.isEmpty) return 0;
    return (widget.novel.comments.length / widget.commentsPerPage).ceil();
  }

  List<NovelComment> get _visibleComments {
    if (_usesRemoteComments) return _loadedCommentPage?.comments ?? const [];
    final start = _commentPage * widget.commentsPerPage;
    final end = (start + widget.commentsPerPage).clamp(
      start,
      widget.novel.comments.length,
    );
    return widget.novel.comments.sublist(start, end);
  }

  String get _commentSummary {
    if (!_usesRemoteComments) return '${widget.novel.comments.length} 条';
    if (_commentsLoading) return '加载中';
    if (_commentError != null) return '加载失败';
    final page = _loadedCommentPage;
    if (page == null) return '—';
    final totalComments = page.totalComments;
    if (totalComments != null) return '$totalComments 条';
    return page.totalPages == 0 ? '评论已加载' : '共 ${page.totalPages} 页';
  }

  Future<void> _startDownload() async {
    final callback = widget.onDownload;
    if (callback == null || _downloadStarting) return;
    setState(() => _downloadStarting = true);
    try {
      await callback();
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('离线下载创建失败，请稍后重试')));
    } finally {
      if (mounted) setState(() => _downloadStarting = false);
    }
  }

  Future<void> _openOriginal() async {
    final callback = widget.onOpenOriginal;
    if (callback == null || _openingOriginal) return;
    setState(() => _openingOriginal = true);
    try {
      await callback();
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('无法打开原作网站')));
    } finally {
      if (mounted) setState(() => _openingOriginal = false);
    }
  }

  List<({String title, List<NovelChapter> chapters})> get _chapterSections {
    final catalog =
        widget.novel.readerNovel?.chapters ?? const <NovelChapter>[];
    final byId = {for (final chapter in catalog) chapter.id: chapter};
    final sections = widget.novel.chapterSections.isEmpty
        ? [(title: '章节', chapters: catalog)]
        : [
            for (final section in widget.novel.chapterSections)
              (
                title: section.title,
                chapters: section.chapterIds
                    .map((id) => byId[id])
                    .whereType<NovelChapter>()
                    .toList(),
              ),
          ];
    if (!_chaptersReversed) return sections;
    return [
      for (final section in sections.reversed)
        (title: section.title, chapters: section.chapters.reversed.toList()),
    ];
  }

  Future<void> _loadCommentPage(
    int pageNumber, {
    bool announceLoading = true,
  }) async {
    final loader = widget.commentPageLoader;
    if (loader == null) {
      setState(() => _commentPage = pageNumber - 1);
      return;
    }
    final generation = ++_commentRequestGeneration;
    _requestedCommentPage = pageNumber;
    if (announceLoading && mounted) {
      setState(() {
        _commentsLoading = true;
        _commentError = null;
        _loadedCommentPage = null;
      });
    }
    try {
      final page = await loader(widget.novel, pageNumber);
      if (!mounted || generation != _commentRequestGeneration) return;
      if (page.pageNumber != pageNumber) {
        throw StateError('Comment loader returned a different page.');
      }
      setState(() {
        _commentPage = page.pageNumber - 1;
        _loadedCommentPage = page;
        _commentError = null;
        _commentsLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _commentRequestGeneration) return;
      setState(() {
        _loadedCommentPage = null;
        _commentError = error;
        _commentsLoading = false;
      });
    }
  }

  List<Widget> _buildCommentSlivers(BuildContext context) {
    if (_commentsLoading) {
      return const [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 36),
          sliver: SliverToBoxAdapter(child: _CommentsLoadingState()),
        ),
      ];
    }
    if (_commentError != null) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 36),
          sliver: SliverToBoxAdapter(
            child: _CommentsErrorState(
              onRetry: () => _loadCommentPage(_requestedCommentPage),
            ),
          ),
        ),
      ];
    }
    if (_visibleComments.isEmpty) {
      return const [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(20, 10, 20, 30),
          sliver: SliverToBoxAdapter(child: Text('暂无评论')),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList.separated(
          key: ValueKey('comments-page-${_commentPage + 1}'),
          itemCount: _visibleComments.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) =>
              _CommentCard(comment: _visibleComments[index]),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
        sliver: SliverToBoxAdapter(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.outlined(
                key: const ValueKey('comments-previous-page'),
                tooltip: '上一页',
                onPressed: _commentPage == 0
                    ? null
                    : () => _loadCommentPage(_commentPage),
                icon: const Icon(Icons.chevron_left),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '第 ${_commentPage + 1} / $_commentPageCount 页',
                  key: const ValueKey('comments-page-indicator'),
                ),
              ),
              IconButton.outlined(
                key: const ValueKey('comments-next-page'),
                tooltip: '下一页',
                onPressed: _commentPage >= _commentPageCount - 1
                    ? null
                    : () => _loadCommentPage(_commentPage + 2),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final novel = widget.novel;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      key: ValueKey('novel-details-${novel.id}'),
      appBar: AppBar(
        title: const Text('小说详情'),
        actions: [
          if (widget.onFavorite != null)
            IconButton(
              key: const ValueKey('favorite-novel-button'),
              tooltip: '加入收藏',
              onPressed: widget.onFavorite,
              icon: const Icon(Icons.favorite_border),
            ),
          IconButton(
            key: const ValueKey('download-novel-button'),
            tooltip: _downloadStarting ? '正在创建离线下载' : '离线下载',
            onPressed: widget.onDownload == null || _downloadStarting
                ? null
                : () => unawaited(_startDownload()),
            icon: _downloadStarting
                ? const SizedBox.square(
                    key: ValueKey('download-novel-loading'),
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: CustomScrollView(
        key: PageStorageKey('novel-details-scroll-${novel.id}'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    novel.chineseTitle,
                    key: const ValueKey('novel-details-chinese-title'),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    novel.japaneseTitle,
                    key: const ValueKey('novel-details-japanese-title'),
                    locale: const Locale('ja', 'JP'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 13),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (novel.author case final author?)
                        ActionChip(
                          key: const ValueKey('novel-author-chip'),
                          avatar: const Icon(Icons.person_outline, size: 17),
                          label: Text(author),
                          onPressed: widget.onAuthorSelected == null
                              ? null
                              : () => widget.onAuthorSelected!(author),
                        ),
                      Chip(label: Text(novel.source)),
                      Chip(label: Text(novel.publicationState.label)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('start-reading-button'),
                      onPressed: () => widget.onOpenReader(null),
                      icon: const Icon(Icons.menu_book),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 11),
                        child: Text('开始阅读'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _MetadataGrid(novel: novel),
                  const SizedBox(height: 24),
                  _DetailSectionTitle(title: '内容简介'),
                  const SizedBox(height: 9),
                  Text(
                    novel.synopsis ?? '暂无简介',
                    key: const ValueKey('novel-synopsis'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(height: 1.65),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 7,
                    children: [
                      for (final tag in novel.tags)
                        ActionChip(
                          key: ValueKey('novel-detail-tag-$tag'),
                          label: Text(tag),
                          onPressed: widget.onTagSelected == null
                              ? null
                              : () => widget.onTagSelected!(tag),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _DetailSectionTitle(title: '翻译覆盖'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 9,
                    runSpacing: 9,
                    children: [
                      for (final coverage in novel.translationCoverage)
                        _CoverageCard(coverage: coverage),
                    ],
                  ),
                  if (widget.onOpenOriginal != null) ...[
                    const SizedBox(height: 14),
                    TextButton.icon(
                      key: const ValueKey('open-original-site-button'),
                      onPressed: _openingOriginal
                          ? null
                          : () => unawaited(_openOriginal()),
                      icon: _openingOriginal
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.open_in_new),
                      label: Text(_openingOriginal ? '正在打开…' : '前往原作网站'),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Expanded(child: _DetailSectionTitle(title: '章节目录')),
                      TextButton.icon(
                        key: const ValueKey('toggle-chapters-button'),
                        onPressed: () => setState(
                          () => _chaptersExpanded = !_chaptersExpanded,
                        ),
                        icon: Icon(
                          _chaptersExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                        ),
                        label: Text(_chaptersExpanded ? '收起目录' : '展开目录'),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${novel.knownChapterCount == null ? '章节数未知' : '${novel.knownChapterCount} 章'} · '
                          '${_chaptersReversed ? '从新到旧' : '从旧到新'}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                      if (_chaptersExpanded)
                        TextButton.icon(
                          key: const ValueKey('reverse-chapters-button'),
                          onPressed: () => setState(
                            () => _chaptersReversed = !_chaptersReversed,
                          ),
                          icon: const Icon(Icons.swap_vert),
                          label: Text(_chaptersReversed ? '倒序' : '正序'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
          if (_chaptersExpanded)
            for (final section in _chapterSections) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    section.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverList.separated(
                  itemCount: section.chapters.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final chapter = section.chapters[index];
                    return Semantics(
                      button: true,
                      label: '阅读第 ${chapter.index} 章，${chapter.chineseTitle}',
                      child: ListTile(
                        key: ValueKey('chapter-${chapter.id}'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        leading: SizedBox(
                          width: 34,
                          child: Text(
                            '${chapter.index}',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        title: Text(chapter.chineseTitle),
                        subtitle: Text(
                          [
                            chapter.japaneseTitle,
                            if (chapter.publishedAt case final publishedAt?)
                              formatCatalogDate(publishedAt),
                          ].join('\n'),
                          locale: const Locale('ja', 'JP'),
                        ),
                        isThreeLine: chapter.publishedAt != null,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => widget.onOpenReader(chapter),
                      ),
                    );
                  },
                ),
              ),
            ],
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 30, 20, 12),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  const Expanded(child: _DetailSectionTitle(title: '读者评论')),
                  Text(
                    _commentSummary,
                    key: const ValueKey('comments-summary'),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          ),
          ..._buildCommentSlivers(context),
        ],
      ),
    );
  }
}

class _CommentsLoadingState extends StatelessWidget {
  const _CommentsLoadingState();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('comments-page-loading'),
      liveRegion: true,
      label: '正在加载评论',
      child: const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }
}

class _CommentsErrorState extends StatelessWidget {
  const _CommentsErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('comments-page-error'),
      liveRegion: true,
      label: '评论加载失败',
      child: Card.outlined(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              const Text('无法加载这一页评论'),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('retry-comments-page'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailSectionTitle extends StatelessWidget {
  const _DetailSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _MetadataGrid extends StatelessWidget {
  const _MetadataGrid({required this.novel});

  final CatalogNovel novel;

  @override
  Widget build(BuildContext context) {
    final items = [
      if (novel.wordCount case final wordCount?)
        ('字数', _compactCount(wordCount)),
      if (novel.knownChapterCount case final chapterCount?)
        ('章节', '$chapterCount'),
      if (novel.points case final points?) ('点数', _compactCount(points)),
      if (novel.views case final views?) ('阅读', _compactCount(views)),
      if (novel.updatedAt case final updatedAt?)
        ('最近更新', formatCatalogDate(updatedAt)),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final item in items)
          Container(
            constraints: const BoxConstraints(minWidth: 108),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.$1, style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 2),
                Text(
                  item.$2,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CoverageCard extends StatelessWidget {
  const _CoverageCard({required this.coverage});

  final TranslationCoverage coverage;

  @override
  Widget build(BuildContext context) {
    final progress = coverage.totalChapters == 0
        ? 0.0
        : coverage.translatedChapters / coverage.totalChapters;
    return Semantics(
      label: '${coverage.source} 翻译覆盖 ${coverage.label}',
      child: Container(
        width: 145,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              coverage.source,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 7),
            LinearProgressIndicator(
              value: progress,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 6),
            Text(
              '${coverage.translatedChapters}/${coverage.totalChapters} 章',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentCard extends StatelessWidget {
  const _CommentCard({required this.comment});

  final NovelComment comment;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card.outlined(
      key: ValueKey('novel-comment-${comment.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  child: Text(comment.author.characters.first),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    comment.author,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                Text(
                  formatCatalogDate(comment.createdAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(comment.body, style: const TextStyle(height: 1.55)),
            for (final reply in comment.replies) ...[
              const SizedBox(height: 11),
              Container(
                key: ValueKey('comment-reply-${reply.id}'),
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reply.author,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(reply.body, style: const TextStyle(height: 1.45)),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _compactCount(int value) {
  if (value >= 10000) {
    final count = value / 10000;
    return '${count.toStringAsFixed(count >= 100 ? 0 : 1)} 万';
  }
  return value.toString();
}
