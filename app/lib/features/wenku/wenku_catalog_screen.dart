import 'dart:async';

import 'package:flutter/material.dart';

import '../../gateway/novelia/novelia_wenku_gateway.dart';
import 'wenku_details_screen.dart';

class WenkuCatalogScreen extends StatefulWidget {
  const WenkuCatalogScreen({required this.gateway, super.key});

  final NoveliaWenkuGateway gateway;

  @override
  State<WenkuCatalogScreen> createState() => _WenkuCatalogScreenState();
}

class _WenkuCatalogScreenState extends State<WenkuCatalogScreen> {
  final _searchController = TextEditingController();
  var _items = const <WenkuNovelSummary>[];
  var _level = WenkuCatalogLevel.all;
  var _loading = true;
  var _loadingMore = false;
  var _pageIndex = -1;
  var _pageCount = 1;
  Object? _failure;
  Object? _loadMoreFailure;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load([String? search]) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _failure = null;
      _loadMoreFailure = null;
    });
    try {
      final page = await widget.gateway.listNovels(
        WenkuCatalogQuery(
          page: 0,
          search: search ?? _searchController.text.trim(),
          level: _level,
        ),
      );
      if (mounted && generation == _generation) {
        setState(() {
          _items = page.items;
          _pageIndex = 0;
          _pageCount = page.pageCount;
        });
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _failure = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loading ||
        _loadingMore ||
        _pageIndex < 0 ||
        _pageIndex + 1 >= _pageCount) {
      return;
    }
    final generation = _generation;
    final targetPage = _pageIndex + 1;
    setState(() {
      _loadingMore = true;
      _loadMoreFailure = null;
    });
    try {
      final page = await widget.gateway.listNovels(
        WenkuCatalogQuery(
          page: targetPage,
          search: _searchController.text.trim(),
          level: _level,
        ),
      );
      if (mounted && generation == _generation) {
        setState(() {
          _items = List.unmodifiable([..._items, ...page.items]);
          _pageIndex = targetPage;
          _pageCount = page.pageCount;
        });
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _loadMoreFailure = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _open(WenkuNovelSummary novel) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            WenkuDetailsScreen(gateway: widget.gateway, summary: novel),
        settings: RouteSettings(name: '/wenku/${novel.id}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('文库小说')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              sliver: SliverToBoxAdapter(
                child: SearchBar(
                  key: const ValueKey('wenku-search-field'),
                  controller: _searchController,
                  hintText: '搜索中日文书名',
                  leading: const Icon(Icons.search),
                  trailing: [
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        tooltip: '清除',
                        onPressed: () {
                          _searchController.clear();
                          _load('');
                        },
                        icon: const Icon(Icons.close),
                      ),
                  ],
                  onChanged: (_) => setState(() {}),
                  onSubmitted: _load,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('分级', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final level in WenkuCatalogLevel.values) ...[
                            ChoiceChip(
                              key: ValueKey('wenku-level-${level.name}'),
                              label: Text(level.label),
                              selected: _level == level,
                              onSelected: (_) {
                                if (_level == level) return;
                                setState(() => _level = level);
                                unawaited(_load());
                              },
                            ),
                            if (level != WenkuCatalogLevel.values.last)
                              const SizedBox(width: 8),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_failure != null)
              SliverFillRemaining(
                child: Center(
                  child: FilledButton.tonalIcon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('载入失败，点击重试'),
                  ),
                ),
              )
            else if (_items.isEmpty)
              const SliverFillRemaining(child: Center(child: Text('没有找到文库小说')))
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                sliver: SliverList.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final novel = _items[index];
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(12),
                        leading: _CatalogCover(uri: novel.coverUri),
                        title: Text(
                          novel.chineseTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            novel.japaneseTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(novel),
                      ),
                    );
                  },
                ),
              ),
              if (_pageIndex + 1 < _pageCount)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                  sliver: SliverToBoxAdapter(
                    child: Center(
                      child: FilledButton.tonalIcon(
                        key: const ValueKey('wenku-load-more-button'),
                        onPressed: _loadingMore ? null : _loadMore,
                        icon: _loadingMore
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                _loadMoreFailure == null
                                    ? Icons.expand_more
                                    : Icons.refresh,
                              ),
                        label: Text(
                          _loadingMore
                              ? '正在载入…'
                              : _loadMoreFailure == null
                              ? '载入更多'
                              : '载入失败，点击重试',
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CatalogCover extends StatelessWidget {
  const _CatalogCover({required this.uri});

  final Uri? uri;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.menu_book_outlined),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        width: 48,
        height: 68,
        child: uri == null
            ? fallback
            : Image.network(
                uri.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
