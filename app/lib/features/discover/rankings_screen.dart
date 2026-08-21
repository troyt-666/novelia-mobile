import 'dart:async';

import 'package:flutter/material.dart';

import 'catalog_card.dart';
import 'catalog_models.dart';

enum RankingPeriod {
  overall('总榜'),
  yearly('年榜'),
  monthly('月榜'),
  weekly('周榜'),
  daily('日榜');

  const RankingPeriod(this.label);

  final String label;
}

@immutable
class RankingsQuery {
  const RankingsQuery({
    this.source,
    this.period = RankingPeriod.overall,
    this.genre,
    this.publicationState,
    this.pageNumber = 1,
  }) : assert(pageNumber > 0);

  final String? source;
  final RankingPeriod period;
  final String? genre;
  final NovelPublicationState? publicationState;
  final int pageNumber;

  RankingsQuery copyWith({
    String? source,
    RankingPeriod? period,
    String? genre,
    NovelPublicationState? publicationState,
    int? pageNumber,
    bool clearSource = false,
    bool clearGenre = false,
    bool clearPublicationState = false,
  }) {
    return RankingsQuery(
      source: clearSource ? null : source ?? this.source,
      period: period ?? this.period,
      genre: clearGenre ? null : genre ?? this.genre,
      publicationState: clearPublicationState
          ? null
          : publicationState ?? this.publicationState,
      pageNumber: pageNumber ?? this.pageNumber,
    );
  }
}

class RankingPageView {
  const RankingPageView({
    required this.novels,
    required this.pageNumber,
    required this.totalPages,
    required this.description,
    this.firstRank = 1,
  }) : assert(pageNumber > 0),
       assert(totalPages >= 0),
       assert(totalPages == 0 || pageNumber <= totalPages),
       assert(firstRank > 0);

  final List<CatalogNovel> novels;
  final int pageNumber;
  final int totalPages;
  final String description;
  final int firstRank;
}

typedef RankingsLoader = Future<RankingPageView> Function(RankingsQuery query);

class RankingsScreen extends StatefulWidget {
  const RankingsScreen({
    required this.novels,
    required this.onOpenNovel,
    required this.onTagSelected,
    this.loader,
    this.onClose,
    super.key,
  });

  final List<CatalogNovel> novels;
  final ValueChanged<CatalogNovel> onOpenNovel;
  final ValueChanged<String> onTagSelected;
  final RankingsLoader? loader;
  final VoidCallback? onClose;

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen> {
  final _scrollController = ScrollController();
  String? _source;
  String? _genre;
  NovelPublicationState? _state;
  RankingPeriod _period = RankingPeriod.overall;
  final List<CatalogNovel> _remoteNovels = [];
  String _remoteDescription = '保留各来源的原生排序';
  var _pageNumber = 1;
  var _totalPages = 1;
  var _firstRank = 1;
  Object? _remoteError;
  var _loading = false;
  var _loadingMore = false;
  var _loadMoreFailed = false;
  var _requestGeneration = 0;

  bool get _isRemote => widget.loader != null;

  RankingsQuery get _query => RankingsQuery(
    source: _source,
    period: _period,
    genre: _genre,
    publicationState: _state,
    pageNumber: _pageNumber,
  );

  @override
  void initState() {
    super.initState();
    if (_isRemote) _source = 'Syosetu';
    _scrollController.addListener(_maybeLoadMore);
    if (_isRemote) unawaited(_loadRemote(reset: true));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_isRemote ||
        !_scrollController.hasClients ||
        _scrollController.position.extentAfter > 600 ||
        _loading ||
        _loadingMore ||
        _loadMoreFailed ||
        _pageNumber >= _totalPages) {
      return;
    }
    unawaited(_loadRemote());
  }

  Future<void> _loadRemote({bool reset = false}) async {
    final loader = widget.loader;
    if (loader == null) return;
    if (reset) {
      _pageNumber = 1;
      _loadMoreFailed = false;
    } else if (_loading || _loadingMore || _pageNumber >= _totalPages) {
      return;
    }
    final nextPage = reset ? 1 : _pageNumber + 1;
    final generation = ++_requestGeneration;
    setState(() {
      if (reset) {
        _remoteNovels.clear();
        _loading = true;
        _remoteError = null;
        _loadMoreFailed = false;
      } else {
        _loadingMore = true;
        _loadMoreFailed = false;
      }
    });
    try {
      final page = await loader(_query.copyWith(pageNumber: nextPage));
      if (!mounted || generation != _requestGeneration) return;
      if (page.pageNumber != nextPage) {
        throw StateError('Ranking loader returned a different page.');
      }
      setState(() {
        _pageNumber = page.pageNumber;
        _totalPages = page.totalPages == 0 ? 1 : page.totalPages;
        _remoteDescription = page.description;
        if (reset) {
          _remoteNovels
            ..clear()
            ..addAll(page.novels);
          _firstRank = page.firstRank;
        } else {
          _remoteNovels.addAll(page.novels);
        }
        _loading = false;
        _loadingMore = false;
        _remoteError = null;
        _loadMoreFailed = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeLoadMore();
      });
    } on Object catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (reset && _remoteNovels.isEmpty) {
          _remoteError = error;
        } else {
          _loadMoreFailed = true;
        }
      });
    }
  }

  void _applyFilter(VoidCallback change) {
    setState(change);
    if (_isRemote) unawaited(_loadRemote(reset: true));
  }

  List<CatalogNovel> get _fixtureRanked {
    final ranked =
        widget.novels.where((novel) {
          return (_source == null || novel.source == _source) &&
              (_genre == null || novel.tags.contains(_genre)) &&
              (_state == null || novel.publicationState == _state);
        }).toList()..sort((a, b) {
          final aPoints = a.points;
          final bPoints = b.points;
          if (aPoints == null && bPoints == null) return 0;
          if (aPoints == null) return 1;
          if (bPoints == null) return -1;
          return bPoints.compareTo(aPoints);
        });
    return _applyFixturePeriod(ranked);
  }

  List<CatalogNovel> _applyFixturePeriod(List<CatalogNovel> novels) {
    if (_period == RankingPeriod.overall) return novels;
    DateTime? latest;
    for (final novel in novels) {
      final updatedAt = novel.updatedAt;
      if (updatedAt != null && (latest == null || updatedAt.isAfter(latest))) {
        latest = updatedAt;
      }
    }
    if (latest == null) return novels;
    final window = switch (_period) {
      RankingPeriod.daily => const Duration(days: 1),
      RankingPeriod.weekly => const Duration(days: 7),
      RankingPeriod.monthly => const Duration(days: 31),
      RankingPeriod.yearly => const Duration(days: 366),
      RankingPeriod.overall => Duration.zero,
    };
    final cutoff = latest.subtract(window);
    return [
      for (final novel in novels)
        if (novel.updatedAt != null && !novel.updatedAt!.isBefore(cutoff))
          novel,
    ];
  }

  List<String> get _sources {
    if (_isRemote) return const ['Syosetu', 'Kakuyomu'];
    final sources = {
      ...widget.novels.map((novel) => novel.source),
      ..._remoteNovels.map((novel) => novel.source),
    }.where((source) => source.isNotEmpty).toList()..sort();
    return sources;
  }

  bool get _supportsPublicationState => !_isRemote || _source != 'Kakuyomu';

  List<String> get _genres {
    return {
      ...widget.novels.expand((novel) => novel.tags),
      ..._remoteNovels.expand((novel) => novel.tags),
    }.toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    final novels = _isRemote
        ? List<CatalogNovel>.of(_remoteNovels)
        : _fixtureRanked;
    final showInitialLoading = _isRemote && _loading && novels.isEmpty;
    final showInitialError =
        _isRemote && _remoteError != null && novels.isEmpty && !_loading;
    return Scaffold(
      key: const ValueKey('rankings-screen'),
      appBar: AppBar(
        title: const Text('小说排行'),
        leading: widget.onClose == null
            ? null
            : IconButton(
                key: const ValueKey('rankings-close-button'),
                tooltip: '返回发现',
                onPressed: widget.onClose,
                icon: const Icon(Icons.arrow_back),
              ),
      ),
      body: showInitialLoading
          ? const Center(
              child: CircularProgressIndicator(
                key: ValueKey('rankings-loading'),
              ),
            )
          : showInitialError
          ? Center(
              child: Column(
                key: const ValueKey('rankings-error'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 44),
                  const SizedBox(height: 12),
                  const Text('排行暂时无法加载'),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    key: const ValueKey('retry-rankings'),
                    onPressed: () => _loadRemote(reset: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            )
          : ListView(
              key: const PageStorageKey('rankings-scroll'),
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Text(
                  _isRemote ? _remoteDescription : '保留各来源的原生排序',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _RankingDropdown<String>(
                      key: const ValueKey('ranking-source-filter'),
                      label: '来源',
                      value: _source,
                      allLabel: _isRemote ? null : '全部来源',
                      values: _sources,
                      itemLabel: (value) => value,
                      onChanged: (value) => _applyFilter(() {
                        _source = value;
                        if (!_supportsPublicationState) _state = null;
                      }),
                    ),
                    _RankingDropdown<RankingPeriod>(
                      key: const ValueKey('ranking-period-filter'),
                      label: '时间',
                      value: _period,
                      values: RankingPeriod.values,
                      itemLabel: (value) => value.label,
                      onChanged: (value) {
                        if (value != null) {
                          _applyFilter(() => _period = value);
                        }
                      },
                    ),
                    _RankingDropdown<String>(
                      key: const ValueKey('ranking-genre-filter'),
                      label: '类型',
                      value: _genre,
                      allLabel: '全部类型',
                      values: _genres,
                      itemLabel: (value) => value,
                      onChanged: (value) => _applyFilter(() => _genre = value),
                    ),
                    if (_supportsPublicationState)
                      _RankingDropdown<NovelPublicationState>(
                        key: const ValueKey('ranking-state-filter'),
                        label: '状态',
                        value: _state,
                        allLabel: '全部状态',
                        values: NovelPublicationState.values,
                        itemLabel: (value) => value.label,
                        onChanged: (value) =>
                            _applyFilter(() => _state = value),
                      ),
                  ],
                ),
                const SizedBox(height: 22),
                if (novels.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: Text('该组合暂无排行数据')),
                  )
                else
                  for (var index = 0; index < novels.length; index++) ...[
                    _RankedNovelRow(
                      rank: _firstRank + index,
                      novel: novels[index],
                      onOpen: () => widget.onOpenNovel(novels[index]),
                      onTagSelected: widget.onTagSelected,
                    ),
                    const SizedBox(height: 12),
                  ],
                if (_loadingMore)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: CircularProgressIndicator(
                        key: ValueKey('rankings-loading-more'),
                      ),
                    ),
                  ),
                if (_loadMoreFailed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Center(
                      child: FilledButton.icon(
                        key: const ValueKey('retry-rankings-load-more'),
                        onPressed: () => _loadRemote(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _RankedNovelRow extends StatelessWidget {
  const _RankedNovelRow({
    required this.rank,
    required this.novel,
    required this.onOpen,
    required this.onTagSelected,
  });

  final int rank;
  final CatalogNovel novel;
  final VoidCallback onOpen;
  final ValueChanged<String> onTagSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 36,
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: rank <= 3 ? Theme.of(context).colorScheme.primary : null,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: CatalogNovelCard(
            novel: novel,
            onOpen: onOpen,
            onTagSelected: onTagSelected,
          ),
        ),
      ],
    );
  }
}

class _RankingDropdown<T> extends StatelessWidget {
  const _RankingDropdown({
    required this.label,
    required this.value,
    required this.values,
    required this.itemLabel,
    required this.onChanged,
    this.allLabel,
    super.key,
  });

  final String label;
  final T? value;
  final List<T> values;
  final String Function(T) itemLabel;
  final ValueChanged<T?> onChanged;
  final String? allLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 188,
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          if (allLabel != null)
            DropdownMenuItem<T>(value: null, child: Text(allLabel!)),
          for (final item in values)
            DropdownMenuItem<T>(value: item, child: Text(itemLabel(item))),
        ],
        onChanged: onChanged,
      ),
    );
  }
}
