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

typedef RankingsLoader = Future<RankingPageView> Function(int pageNumber);

class RankingsScreen extends StatefulWidget {
  const RankingsScreen({
    required this.novels,
    required this.onOpenNovel,
    this.loader,
    super.key,
  });

  final List<CatalogNovel> novels;
  final ValueChanged<CatalogNovel> onOpenNovel;
  final RankingsLoader? loader;

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen> {
  String? _source;
  String? _genre;
  NovelPublicationState? _state;
  RankingPeriod _period = RankingPeriod.overall;
  RankingPageView? _remotePage;
  Object? _remoteError;
  var _requestedPage = 1;
  var _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    if (widget.loader != null) unawaited(_loadRemote(1));
  }

  Future<void> _loadRemote([int? pageNumber]) async {
    final loader = widget.loader;
    if (loader == null) return;
    final targetPage = pageNumber ?? _requestedPage;
    if (targetPage < 1) return;
    final generation = ++_requestGeneration;
    _requestedPage = targetPage;
    setState(() {
      _remotePage = null;
      _remoteError = null;
    });
    try {
      final page = await loader(targetPage);
      if (!mounted || generation != _requestGeneration) return;
      if (page.pageNumber != targetPage) {
        throw StateError('Ranking loader returned a different page.');
      }
      setState(() => _remotePage = page);
    } on Object catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() => _remoteError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loader != null) return _buildRemote(context);
    final sources = widget.novels.map((novel) => novel.source).toSet().toList()
      ..sort();
    final genres = widget.novels.expand((novel) => novel.tags).toSet().toList()
      ..sort();
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

    return Scaffold(
      key: const ValueKey('rankings-screen'),
      appBar: AppBar(title: const Text('小说排行')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            '保留各来源的原生排序',
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
                allLabel: '全部来源',
                values: sources,
                itemLabel: (value) => value,
                onChanged: (value) => setState(() => _source = value),
              ),
              _RankingDropdown<RankingPeriod>(
                key: const ValueKey('ranking-period-filter'),
                label: '时间',
                value: _period,
                values: RankingPeriod.values,
                itemLabel: (value) => value.label,
                onChanged: (value) {
                  if (value != null) setState(() => _period = value);
                },
              ),
              _RankingDropdown<String>(
                key: const ValueKey('ranking-genre-filter'),
                label: '类型',
                value: _genre,
                allLabel: '全部类型',
                values: genres,
                itemLabel: (value) => value,
                onChanged: (value) => setState(() => _genre = value),
              ),
              _RankingDropdown<NovelPublicationState>(
                key: const ValueKey('ranking-state-filter'),
                label: '状态',
                value: _state,
                allLabel: '全部状态',
                values: NovelPublicationState.values,
                itemLabel: (value) => value.label,
                onChanged: (value) => setState(() => _state = value),
              ),
            ],
          ),
          const SizedBox(height: 22),
          if (ranked.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: Text('该组合暂无排行数据')),
            )
          else
            for (var index = 0; index < ranked.length; index++) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 36,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: index < 3
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: CatalogNovelCard(
                      novel: ranked[index],
                      onOpen: () => widget.onOpenNovel(ranked[index]),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }

  Widget _buildRemote(BuildContext context) {
    final page = _remotePage;
    final error = _remoteError;
    return Scaffold(
      key: const ValueKey('rankings-screen'),
      appBar: AppBar(title: const Text('小说排行')),
      body: page == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator(
                      key: ValueKey('rankings-loading'),
                    )
                  : Column(
                      key: const ValueKey('rankings-error'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.cloud_off_outlined, size: 44),
                        const SizedBox(height: 12),
                        const Text('排行暂时无法加载'),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          key: const ValueKey('retry-rankings'),
                          onPressed: () => _loadRemote(),
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Text(
                  page.description,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                if (page.novels.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: Text('该排行当前没有条目')),
                  )
                else
                  for (var index = 0; index < page.novels.length; index++) ...[
                    _RankedNovelRow(
                      rank: page.firstRank + index,
                      novel: page.novels[index],
                      onOpen: () => widget.onOpenNovel(page.novels[index]),
                    ),
                    const SizedBox(height: 12),
                  ],
                if (page.totalPages > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.outlined(
                          key: const ValueKey('rankings-previous-page'),
                          tooltip: '上一页',
                          onPressed: page.pageNumber <= 1
                              ? null
                              : () => _loadRemote(page.pageNumber - 1),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            '第 ${page.pageNumber} / ${page.totalPages} 页',
                            key: const ValueKey('rankings-page-indicator'),
                          ),
                        ),
                        IconButton.outlined(
                          key: const ValueKey('rankings-next-page'),
                          tooltip: '下一页',
                          onPressed: page.pageNumber >= page.totalPages
                              ? null
                              : () => _loadRemote(page.pageNumber + 1),
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
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
  });

  final int rank;
  final CatalogNovel novel;
  final VoidCallback onOpen;

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
          child: CatalogNovelCard(novel: novel, onOpen: onOpen),
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
      width: 166,
      child: DropdownButtonFormField<T>(
        initialValue: value,
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
