import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/model/reader_models.dart';
import '../discover/catalog_card.dart';
import '../discover/catalog_models.dart';
import 'novel_comments_section.dart';

class NovelDetailsScreen extends StatefulWidget {
  const NovelDetailsScreen({
    required this.novel,
    required this.onOpenReader,
    this.onFavorite,
    this.onDownload,
    this.onOpenOriginal,
    this.onOpenNovelia,
    this.onAuthorSelected,
    this.onTagSelected,
    this.commentPageLoader,
    this.commentsPerPage = 2,
    super.key,
  });

  final CatalogNovel novel;
  final ValueChanged<NovelChapter?> onOpenReader;
  final FutureOr<CatalogNovel?> Function(CatalogNovel novel)? onFavorite;
  final FutureOr<void> Function()? onDownload;
  final FutureOr<void> Function()? onOpenOriginal;
  final FutureOr<void> Function()? onOpenNovelia;
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
  bool _downloadStarting = false;
  bool _openingWebsite = false;
  late CatalogNovel _favoriteNovel = widget.novel;
  bool get _isFavorite => _favoriteNovel.isFavorite;
  bool _favoriteStarting = false;

  @override
  void didUpdateWidget(covariant NovelDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.novel.id != widget.novel.id ||
        oldWidget.novel.isFavorite != widget.novel.isFavorite ||
        oldWidget.novel.favoriteFolderId != widget.novel.favoriteFolderId) {
      _favoriteNovel = widget.novel;
    }
  }

  Future<void> _startFavorite() async {
    final callback = widget.onFavorite;
    if (callback == null || _favoriteStarting) return;
    setState(() => _favoriteStarting = true);
    try {
      final updated = await callback(_favoriteNovel);
      if (mounted && updated != null) {
        setState(() => _favoriteNovel = updated);
      }
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('收藏更新失败，请检查网络后重试')));
    } finally {
      if (mounted) setState(() => _favoriteStarting = false);
    }
  }

  Future<void> _startDownload() async {
    final callback = widget.onDownload;
    if (callback == null || _downloadStarting) return;
    setState(() => _downloadStarting = true);
    try {
      await callback();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已加入离线下载')));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('离线下载创建失败，请稍后重试')));
    } finally {
      if (mounted) setState(() => _downloadStarting = false);
    }
  }

  Future<void> _openWebsite(FutureOr<void> Function()? callback) async {
    if (callback == null || _openingWebsite) return;
    setState(() => _openingWebsite = true);
    try {
      await callback();
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('无法打开网页，请稍后重试')));
    } finally {
      if (mounted) setState(() => _openingWebsite = false);
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
              tooltip: _isFavorite ? '取消收藏' : '加入收藏',
              color: _isFavorite ? colors.primary : null,
              onPressed: _favoriteStarting
                  ? null
                  : () => unawaited(_startFavorite()),
              icon: Icon(
                _isFavorite ? Icons.favorite : Icons.favorite_border,
                key: ValueKey(
                  _isFavorite ? 'favorite-icon-solid' : 'favorite-icon-hollow',
                ),
              ),
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
                  if (widget.onOpenNovelia != null)
                    TextButton.icon(
                      key: const ValueKey('open-novelia-button'),
                      onPressed: _openingWebsite
                          ? null
                          : () => unawaited(_openWebsite(widget.onOpenNovelia)),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('在 Novelia 打开'),
                    ),
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
                      onPressed: _openingWebsite
                          ? null
                          : () =>
                                unawaited(_openWebsite(widget.onOpenOriginal)),
                      icon: _openingWebsite
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.open_in_new),
                      label: Text(_openingWebsite ? '正在打开…' : '前往原作网站'),
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
          NovelCommentsSection(
            key: ValueKey('novel-comments-${novel.id}'),
            comments: novel.comments,
            commentsPerPage: widget.commentsPerPage,
            loadPage: widget.commentPageLoader == null
                ? null
                : (pageNumber) => widget.commentPageLoader!(novel, pageNumber),
          ),
        ],
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
            if (coverage.isKnown)
              LinearProgressIndicator(
                value: coverage.totalChapters == 0
                    ? 0
                    : coverage.translatedChapters! / coverage.totalChapters!,
                borderRadius: BorderRadius.circular(4),
              ),
            const SizedBox(height: 6),
            Text(
              coverage.isKnown
                  ? '${coverage.countLabel} 章'
                  : coverage.countLabel,
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
