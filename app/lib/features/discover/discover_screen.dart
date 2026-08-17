import 'dart:async';

import 'package:flutter/material.dart';

import 'catalog_card.dart';
import 'catalog_models.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({
    required this.novels,
    required this.onOpenNovel,
    required this.onOpenRankings,
    required this.catalogAvailability,
    this.continuedNovel,
    this.continuedProgress,
    this.onContinueReading,
    this.initialCriteria = const CatalogCriteria(),
    this.onCriteriaRequested,
    this.onSearchRequested,
    this.onLoadMoreRequested,
    this.catalogTotalCount,
    this.catalogHasMore = false,
    this.catalogLoadingMore = false,
    this.catalogLoadMoreFailed = false,
    this.mostClickedNovels = const [],
    this.recentSearches = const [],
    this.onSearchCommitted,
    super.key,
  });

  final List<CatalogNovel> novels;
  final CatalogAvailability catalogAvailability;
  final ValueChanged<CatalogNovel> onOpenNovel;
  final VoidCallback onOpenRankings;
  final CatalogNovel? continuedNovel;
  final double? continuedProgress;
  final VoidCallback? onContinueReading;
  final CatalogCriteria initialCriteria;
  final CatalogCriteriaRequested? onCriteriaRequested;

  /// Legacy search-only boundary retained while composition roots migrate to
  /// [onCriteriaRequested].
  final FutureOr<void> Function(String query)? onSearchRequested;
  final FutureOr<void> Function()? onLoadMoreRequested;
  final int? catalogTotalCount;
  final bool catalogHasMore;
  final bool catalogLoadingMore;
  final bool catalogLoadMoreFailed;
  final List<CatalogNovel> mostClickedNovels;
  final List<String> recentSearches;
  final ValueChanged<String>? onSearchCommitted;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with AutomaticKeepAliveClientMixin {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  late String _query;
  String? _authoritativeRemoteQuery;
  CatalogCriteria? _authoritativeRemoteCriteria;
  late String? _source;
  late NovelPublicationState? _publicationState;
  late String? _translationSource;
  late String? _exactTag;
  late CatalogSort _sort;
  bool _showFilters = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _applyCriteria(widget.initialCriteria);
    if (widget.onCriteriaRequested != null) {
      _authoritativeRemoteCriteria = _criteria;
    }
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void didUpdateWidget(covariant DiscoverScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialCriteria != oldWidget.initialCriteria &&
        widget.initialCriteria != _criteria) {
      _applyCriteria(widget.initialCriteria);
      if (widget.onCriteriaRequested != null) {
        _authoritativeRemoteCriteria = _criteria;
      }
    }
    if (widget.onCriteriaRequested != null &&
        oldWidget.onCriteriaRequested == null) {
      _authoritativeRemoteCriteria = _criteria;
    } else if (widget.onCriteriaRequested == null &&
        oldWidget.onCriteriaRequested != null) {
      _authoritativeRemoteCriteria = null;
    }
  }

  CatalogCriteria get _criteria => CatalogCriteria(
    search: _query.trim(),
    source: _source,
    publicationState: _publicationState,
    translationSource: _translationSource,
    exactTag: _exactTag,
    sort: _sort,
  );

  void _applyCriteria(CatalogCriteria criteria) {
    _query = criteria.search;
    _searchController.text = criteria.search;
    _source = criteria.source;
    _publicationState = criteria.publicationState;
    _translationSource = criteria.translationSource;
    _exactTag = criteria.exactTag;
    _sort = criteria.sort;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (_scrollController.position.extentAfter > 600 ||
        !widget.catalogHasMore ||
        widget.catalogLoadingMore ||
        widget.catalogLoadMoreFailed) {
      return;
    }
    _requestLoadMore();
  }

  void _requestLoadMore() {
    final callback = widget.onLoadMoreRequested;
    if (callback == null) return;
    unawaited(Future<void>.sync(callback).catchError((_) {}));
  }

  List<CatalogNovel> get _filteredNovels {
    final normalizedQuery = _query.trim().toLowerCase();
    final typedRemoteResultsAreAuthoritative =
        widget.onCriteriaRequested != null &&
        _authoritativeRemoteCriteria == _criteria;
    if (typedRemoteResultsAreAuthoritative) {
      return List<CatalogNovel>.of(widget.novels);
    }
    final remoteResultsAreAuthoritative =
        widget.onSearchRequested != null &&
        _authoritativeRemoteQuery == _query.trim();
    final result = widget.novels.where((novel) {
      final matchesQuery =
          remoteResultsAreAuthoritative ||
          normalizedQuery.isEmpty ||
          novel.chineseTitle.toLowerCase().contains(normalizedQuery) ||
          novel.japaneseTitle.toLowerCase().contains(normalizedQuery) ||
          (novel.author?.toLowerCase().contains(normalizedQuery) ?? false);
      final matchesSource = _source == null || novel.source == _source;
      final matchesState =
          _publicationState == null ||
          novel.publicationState == _publicationState;
      final matchesTranslation =
          _translationSource == null ||
          (novel.coverageFor(_translationSource!)?.hasTranslation ?? false);
      final matchesTag = _exactTag == null || novel.tags.contains(_exactTag);
      return matchesQuery &&
          matchesSource &&
          matchesState &&
          matchesTranslation &&
          matchesTag;
    }).toList();

    switch (_sort) {
      case CatalogSort.recentlyUpdated:
        result.sort(
          (a, b) => _compareNullableDescending(a.updatedAt, b.updatedAt),
        );
      case CatalogSort.mostClicked:
        result.sort((a, b) => _compareNullableDescending(a.views, b.views));
      case CatalogSort.relevance:
        result.sort((a, b) {
          if (normalizedQuery.isEmpty) {
            return _compareNullableDescending(a.points, b.points);
          }
          final aStarts = a.chineseTitle.toLowerCase().startsWith(
            normalizedQuery,
          );
          final bStarts = b.chineseTitle.toLowerCase().startsWith(
            normalizedQuery,
          );
          if (aStarts == bStarts) {
            return _compareNullableDescending(a.points, b.points);
          }
          return aStarts ? -1 : 1;
        });
    }
    return result;
  }

  void _setQuery(String value, {bool commit = false}) {
    setState(() {
      _query = value;
      _exactTag = null;
      if (commit && widget.onCriteriaRequested != null) {
        _authoritativeRemoteCriteria = _criteria;
      } else if (commit && widget.onSearchRequested != null) {
        _authoritativeRemoteQuery = value.trim();
      } else if (_authoritativeRemoteQuery != value.trim()) {
        _authoritativeRemoteQuery = null;
      }
    });
    if (commit && value.trim().isNotEmpty) {
      widget.onSearchCommitted?.call(value.trim());
    }
    if (commit) {
      if (widget.onCriteriaRequested != null) {
        _requestTypedCriteria();
      } else if (widget.onSearchRequested case final callback?) {
        unawaited(
          Future<void>.sync(() => callback(value.trim())).catchError((_) {}),
        );
      }
    }
  }

  void _selectTag(String tag) {
    _changeCriteria(() {
      _exactTag = tag;
      _query = '';
      _searchController.clear();
    });
  }

  void _clearFilters() {
    _changeCriteria(() {
      _source = null;
      _publicationState = null;
      _translationSource = null;
      _exactTag = null;
      _sort = CatalogSort.recentlyUpdated;
    });
  }

  void _selectSource(String? value) {
    _changeCriteria(() => _source = value);
  }

  void _selectPublicationState(NovelPublicationState? value) {
    _changeCriteria(() => _publicationState = value);
  }

  void _selectTranslationSource(String? value) {
    _changeCriteria(() => _translationSource = value);
  }

  void _selectSort(CatalogSort value) {
    _changeCriteria(() => _sort = value);
  }

  void _changeCriteria(VoidCallback change) {
    setState(() {
      change();
      if (widget.onCriteriaRequested != null) {
        _authoritativeRemoteCriteria = _criteria;
      }
    });
    _requestTypedCriteria();
  }

  void _requestTypedCriteria() {
    final callback = widget.onCriteriaRequested;
    if (callback == null) return;
    final criteria = _criteria;
    unawaited(Future<void>.sync(() => callback(criteria)).catchError((_) {}));
  }

  String _resultCountLabel(int loadedCount) {
    final total = widget.catalogTotalCount;
    if (total != null) {
      return _exactTag == null
          ? '找到 $total 部小说'
          : '标签“$_exactTag” · 共 $total 部';
    }
    final remoteCatalog =
        widget.onCriteriaRequested != null || widget.onSearchRequested != null;
    if (remoteCatalog) {
      return _exactTag == null
          ? '已加载 $loadedCount 部小说'
          : '标签“$_exactTag” · 已加载 $loadedCount 部';
    }
    return _exactTag == null
        ? '找到 $loadedCount 部小说'
        : '标签“$_exactTag” · $loadedCount 部';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final novels = _filteredNovels;
    final sources = widget.novels.map((novel) => novel.source).toSet().toList()
      ..sort();
    final translationSources = widget.novels
        .expand((novel) => novel.translationCoverage)
        .map((coverage) => coverage.source)
        .toSet()
        .toList();
    final mostClicked = widget.mostClickedNovels.isNotEmpty
        ? List<CatalogNovel>.of(widget.mostClickedNovels)
        : (widget.novels.where((novel) => novel.views != null).toList()
            ..sort((a, b) => _compareNullableDescending(a.views, b.views)));
    final recentlyUpdated =
        widget.novels.where((novel) => novel.updatedAt != null).toList()..sort(
          (a, b) => _compareNullableDescending(a.updatedAt, b.updatedAt),
        );

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        key: const PageStorageKey('discover-scroll'),
        controller: _scrollController,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '发现',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '找到下一个想读的故事',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('open-rankings-button'),
                    onPressed: widget.onOpenRankings,
                    icon: const Icon(Icons.leaderboard_outlined),
                    label: const Text('排行'),
                  ),
                ],
              ),
            ),
          ),
          if (widget.catalogAvailability != CatalogAvailability.available)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
              sliver: SliverToBoxAdapter(
                child: _CatalogAvailabilityNotice(
                  availability: widget.catalogAvailability,
                ),
              ),
            ),
          if (widget.continuedNovel case final continued?) ...[
            _SectionHeader(title: '继续阅读'),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverToBoxAdapter(
                child: CatalogNovelCard(
                  novel: continued,
                  progress: widget.continuedProgress,
                  onOpen:
                      widget.onContinueReading ??
                      () => widget.onOpenNovel(continued),
                ),
              ),
            ),
          ],
          if (mostClicked.isNotEmpty) ...[
            _SectionHeader(title: '最多点击'),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 190,
                child: ListView.separated(
                  key: const ValueKey('most-clicked-shelf'),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  itemCount: mostClicked.take(4).length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final novel = mostClicked[index];
                    return SizedBox(
                      width: 302,
                      child: CatalogNovelCard(
                        compact: true,
                        novel: novel,
                        onOpen: () => widget.onOpenNovel(novel),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
          if (recentlyUpdated.isNotEmpty) ...[
            _SectionHeader(title: '最近更新'),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverList.separated(
                itemCount: recentlyUpdated.take(3).length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final novel = recentlyUpdated[index];
                  return CatalogNovelCard(
                    novel: novel,
                    compact: true,
                    onOpen: () => widget.onOpenNovel(novel),
                  );
                },
              ),
            ),
          ],
          _SectionHeader(title: '全部小说', topPadding: 30),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SearchBar(
                    key: const ValueKey('discover-search-field'),
                    controller: _searchController,
                    hintText: '搜索中日文书名或作者',
                    leading: const Icon(Icons.search),
                    trailing: [
                      if (_query.isNotEmpty)
                        IconButton(
                          key: const ValueKey('clear-discover-search'),
                          tooltip: '清除搜索',
                          onPressed: () {
                            _searchController.clear();
                            _setQuery('', commit: true);
                          },
                          icon: const Icon(Icons.close),
                        ),
                    ],
                    onChanged: _setQuery,
                    onSubmitted: (value) => _setQuery(value, commit: true),
                  ),
                  if (widget.recentSearches.isNotEmpty && _query.isEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final query in widget.recentSearches.take(4))
                          InputChip(
                            key: ValueKey('recent-search-$query'),
                            avatar: const Icon(Icons.history, size: 16),
                            label: Text(query),
                            onPressed: () {
                              _searchController.text = query;
                              _setQuery(query, commit: true);
                            },
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        key: const ValueKey('discover-filters-button'),
                        onPressed: () =>
                            setState(() => _showFilters = !_showFilters),
                        icon: const Icon(Icons.tune),
                        label: Text(_showFilters ? '收起筛选' : '筛选'),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<CatalogSort>(
                          key: const ValueKey('catalog-sort-dropdown'),
                          initialValue: _sort,
                          decoration: const InputDecoration(
                            labelText: '排序',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            for (final sort in CatalogSort.values)
                              DropdownMenuItem(
                                value: sort,
                                child: Text(sort.label),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) _selectSort(value);
                          },
                        ),
                      ),
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    alignment: Alignment.topCenter,
                    child: _showFilters
                        ? Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: _CatalogFilters(
                              sources: sources,
                              translationSources: translationSources,
                              selectedSource: _source,
                              selectedState: _publicationState,
                              selectedTranslationSource: _translationSource,
                              exactTag: _exactTag,
                              onSourceSelected: _selectSource,
                              onStateSelected: _selectPublicationState,
                              onTranslationSelected: _selectTranslationSource,
                              onClear: _clearFilters,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _resultCountLabel(novels.length),
                    key: const ValueKey('catalog-result-count'),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          ),
          if (novels.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyCatalog(),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              sliver: SliverList.separated(
                key: const ValueKey('discover-search-results'),
                itemCount: novels.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final novel = novels[index];
                  return CatalogNovelCard(
                    novel: novel,
                    onOpen: () {
                      final committedQuery = _query.trim();
                      if (committedQuery.isNotEmpty) {
                        widget.onSearchCommitted?.call(committedQuery);
                      }
                      widget.onOpenNovel(novel);
                    },
                    onTagSelected: _selectTag,
                  );
                },
              ),
            ),
          if (widget.onLoadMoreRequested != null &&
              (widget.catalogHasMore ||
                  widget.catalogLoadingMore ||
                  widget.catalogLoadMoreFailed))
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              sliver: SliverToBoxAdapter(
                child: _CatalogPageFooter(
                  loading: widget.catalogLoadingMore,
                  failed: widget.catalogLoadMoreFailed,
                  onRetry: _requestLoadMore,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CatalogPageFooter extends StatelessWidget {
  const _CatalogPageFooter({
    required this.loading,
    required this.failed,
    required this.onRetry,
  });

  final bool loading;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(
            key: ValueKey('catalog-load-more-progress'),
          ),
        ),
      );
    }
    return Center(
      child: OutlinedButton.icon(
        key: ValueKey(failed ? 'retry-catalog-page' : 'load-next-catalog-page'),
        onPressed: onRetry,
        icon: Icon(failed ? Icons.refresh : Icons.expand_more),
        label: Text(failed ? '加载失败，重试' : '加载更多'),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.topPadding = 22});

  final String title;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, 10),
      sliver: SliverToBoxAdapter(
        child: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _CatalogFilters extends StatelessWidget {
  const _CatalogFilters({
    required this.sources,
    required this.translationSources,
    required this.selectedSource,
    required this.selectedState,
    required this.selectedTranslationSource,
    required this.onSourceSelected,
    required this.onStateSelected,
    required this.onTranslationSelected,
    required this.onClear,
    this.exactTag,
  });

  final List<String> sources;
  final List<String> translationSources;
  final String? selectedSource;
  final NovelPublicationState? selectedState;
  final String? selectedTranslationSource;
  final String? exactTag;
  final ValueChanged<String?> onSourceSelected;
  final ValueChanged<NovelPublicationState?> onStateSelected;
  final ValueChanged<String?> onTranslationSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _FilterLabel(label: '来源'),
            Wrap(
              spacing: 7,
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: selectedSource == null,
                  onSelected: (_) => onSourceSelected(null),
                ),
                for (final source in sources)
                  ChoiceChip(
                    key: ValueKey('filter-source-$source'),
                    label: Text(source),
                    selected: selectedSource == source,
                    onSelected: (selected) =>
                        onSourceSelected(selected ? source : null),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _FilterLabel(label: '状态'),
            Wrap(
              spacing: 7,
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: selectedState == null,
                  onSelected: (_) => onStateSelected(null),
                ),
                for (final state in NovelPublicationState.values)
                  ChoiceChip(
                    key: ValueKey('filter-state-${state.name}'),
                    label: Text(state.label),
                    selected: selectedState == state,
                    onSelected: (selected) =>
                        onStateSelected(selected ? state : null),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _FilterLabel(label: '翻译来源（至少一章）'),
            Wrap(
              spacing: 7,
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: selectedTranslationSource == null,
                  onSelected: (_) => onTranslationSelected(null),
                ),
                for (final source in translationSources)
                  ChoiceChip(
                    key: ValueKey('filter-translation-$source'),
                    label: Text(source),
                    selected: selectedTranslationSource == source,
                    onSelected: (selected) =>
                        onTranslationSelected(selected ? source : null),
                  ),
              ],
            ),
            if (exactTag != null) ...[
              const SizedBox(height: 8),
              Text('精确标签：$exactTag'),
            ],
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('clear-catalog-filters'),
                onPressed: onClear,
                icon: const Icon(Icons.restart_alt),
                label: const Text('重置筛选'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterLabel extends StatelessWidget {
  const _FilterLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(label, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('没有匹配的小说', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text('请尝试其他关键词或减少筛选条件。'),
          ],
        ),
      ),
    );
  }
}

class _CatalogAvailabilityNotice extends StatelessWidget {
  const _CatalogAvailabilityNotice({required this.availability});

  final CatalogAvailability availability;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = switch (availability) {
      CatalogAvailability.authenticationRequired => (
        Icons.lock_outline,
        '实时目录需要登录',
        '当前显示已保存的内容；小说详情、章节与评论仍可匿名读取。',
      ),
      CatalogAvailability.offline => (
        Icons.cloud_off_outlined,
        '当前处于离线状态',
        '显示已保存的发现内容，连网后将重新验证。',
      ),
      CatalogAvailability.available => throw StateError(
        'Available catalogs do not need an availability notice.',
      ),
    };
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('catalog-availability-notice'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.tertiaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colors.onTertiaryContainer),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colors.onTertiaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onTertiaryContainer,
                    ),
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

int _compareNullableDescending<T extends Comparable<dynamic>>(T? a, T? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}
