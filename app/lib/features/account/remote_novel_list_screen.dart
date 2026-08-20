import 'dart:async';

import 'package:flutter/material.dart';

import '../discover/catalog_card.dart';
import '../discover/catalog_models.dart';

class RemoteNovelPageView {
  RemoteNovelPageView({
    required List<CatalogNovel> novels,
    required this.pageNumber,
    required this.totalPages,
  }) : novels = List.unmodifiable(novels) {
    if (pageNumber < 1) throw ArgumentError.value(pageNumber, 'pageNumber');
    if (totalPages < 0 || (totalPages > 0 && pageNumber > totalPages)) {
      throw ArgumentError.value(totalPages, 'totalPages');
    }
  }

  final List<CatalogNovel> novels;
  final int pageNumber;
  final int totalPages;
}

typedef RemoteNovelPageLoader = Future<RemoteNovelPageView> Function(int page);
typedef FavoriteFolderPageLoader =
    Future<RemoteNovelPageView> Function(String folderId, int page);
typedef RemoteNovelRemoveHandler = FutureOr<void> Function(CatalogNovel novel);

class RemoteNovelListScreen extends StatefulWidget {
  const RemoteNovelListScreen({
    required this.title,
    required this.loader,
    required this.onOpenNovel,
    required this.onTagSelected,
    this.onRemoveNovel,
    super.key,
  });

  final String title;
  final RemoteNovelPageLoader loader;
  final ValueChanged<CatalogNovel> onOpenNovel;
  final ValueChanged<String> onTagSelected;
  final RemoteNovelRemoveHandler? onRemoveNovel;

  @override
  State<RemoteNovelListScreen> createState() => _RemoteNovelListScreenState();
}

class _RemoteNovelListScreenState extends State<RemoteNovelListScreen> {
  RemoteNovelPageView? _page;
  Object? _error;
  var _requestedPage = 1;
  var _generation = 0;
  final _removingNovelIds = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load(1));
  }

  Future<void> _load([int? requestedPage]) async {
    final target = requestedPage ?? _requestedPage;
    if (target < 1) return;
    final generation = ++_generation;
    setState(() {
      _requestedPage = target;
      _page = null;
      _error = null;
    });
    try {
      final page = await widget.loader(target);
      if (!mounted || generation != _generation) return;
      if (page.pageNumber != target) {
        throw StateError('Remote collection returned a different page.');
      }
      setState(() => _page = page);
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error);
    }
  }

  Future<void> _removeNovel(CatalogNovel novel) async {
    final handler = widget.onRemoveNovel;
    final page = _page;
    if (handler == null ||
        page == null ||
        _removingNovelIds.contains(novel.id)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出收藏夹？'),
        content: Text('将《${novel.chineseTitle}》从当前收藏夹移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-remove-favorite'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _removingNovelIds.add(novel.id));
    try {
      await handler(novel);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已移出收藏夹')));
      final targetPage = page.novels.length == 1 && page.pageNumber > 1
          ? page.pageNumber - 1
          : page.pageNumber;
      await _load(targetPage);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('移除失败，请检查网络后重试')));
    } finally {
      if (mounted) setState(() => _removingNovelIds.remove(novel.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final error = _error;
    return Scaffold(
      key: const ValueKey('remote-novel-list-screen'),
      appBar: AppBar(title: Text(widget.title)),
      body: page == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator(
                      key: ValueKey('remote-novel-list-loading'),
                    )
                  : Column(
                      key: const ValueKey('remote-novel-list-error'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.cloud_off_outlined, size: 44),
                        const SizedBox(height: 12),
                        const Text('列表暂时无法加载'),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          key: const ValueKey('retry-remote-novel-list'),
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
            )
          : _RemoteNovelPage(
              page: page,
              onOpenNovel: widget.onOpenNovel,
              onTagSelected: widget.onTagSelected,
              onRemoveNovel: widget.onRemoveNovel == null ? null : _removeNovel,
              removingNovelIds: _removingNovelIds,
              onPrevious: page.pageNumber > 1
                  ? () => _load(page.pageNumber - 1)
                  : null,
              onNext: page.totalPages > 0 && page.pageNumber < page.totalPages
                  ? () => _load(page.pageNumber + 1)
                  : null,
            ),
    );
  }
}

class _RemoteNovelPage extends StatelessWidget {
  const _RemoteNovelPage({
    required this.page,
    required this.onOpenNovel,
    required this.onTagSelected,
    required this.onRemoveNovel,
    required this.removingNovelIds,
    required this.onPrevious,
    required this.onNext,
  });

  final RemoteNovelPageView page;
  final ValueChanged<CatalogNovel> onOpenNovel;
  final ValueChanged<String> onTagSelected;
  final ValueChanged<CatalogNovel>? onRemoveNovel;
  final Set<String> removingNovelIds;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        if (page.novels.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 56),
            child: Center(child: Text('这里还没有小说')),
          )
        else
          for (var index = 0; index < page.novels.length; index++) ...[
            CatalogNovelCard(
              novel: page.novels[index],
              onOpen: () => onOpenNovel(page.novels[index]),
              onTagSelected: onTagSelected,
              footer: onRemoveNovel == null
                  ? null
                  : Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                        child: TextButton.icon(
                          key: ValueKey(
                            'remove-favorite-${page.novels[index].id}',
                          ),
                          onPressed:
                              removingNovelIds.contains(page.novels[index].id)
                              ? null
                              : () => onRemoveNovel!(page.novels[index]),
                          icon: removingNovelIds.contains(page.novels[index].id)
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.heart_broken_outlined),
                          label: const Text('移出收藏夹'),
                        ),
                      ),
                    ),
            ),
            if (index + 1 < page.novels.length) const SizedBox(height: 12),
          ],
        if (page.totalPages > 1) ...[
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.outlined(
                key: const ValueKey('remote-novel-list-previous'),
                tooltip: '上一页',
                onPressed: onPrevious,
                icon: const Icon(Icons.chevron_left),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('${page.pageNumber} / ${page.totalPages}'),
              ),
              IconButton.outlined(
                key: const ValueKey('remote-novel-list-next'),
                tooltip: '下一页',
                onPressed: onNext,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
