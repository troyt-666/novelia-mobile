import 'package:flutter/material.dart';

import '../discover/catalog_models.dart';

typedef NovelDetailsBuilder =
    Widget Function(BuildContext context, CatalogNovel novel);

/// Route-level gate that hydrates production outlines on demand.
class NovelDetailsLoaderScreen extends StatefulWidget {
  const NovelDetailsLoaderScreen({
    required this.outline,
    required this.builder,
    this.loader,
    super.key,
  });

  final CatalogNovel outline;
  final NovelDetailsLoader? loader;
  final NovelDetailsBuilder builder;

  @override
  State<NovelDetailsLoaderScreen> createState() =>
      _NovelDetailsLoaderScreenState();
}

class _NovelDetailsLoaderScreenState extends State<NovelDetailsLoaderScreen> {
  late Future<CatalogNovel> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<CatalogNovel> _load() async {
    final loader = widget.loader;
    if (loader == null) return widget.outline;
    final novel = await loader(widget.outline);
    if (novel.id != widget.outline.id) {
      throw StateError('Hydrated novel ID does not match its outline.');
    }
    return novel;
  }

  void _retry() => setState(() {
    _future = _load();
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CatalogNovel>(
      future: _future,
      builder: (context, snapshot) {
        final novel = snapshot.data;
        if (novel != null) return widget.builder(context, novel);
        return Scaffold(
          key: const ValueKey('novel-details-loader-screen'),
          appBar: AppBar(title: const Text('小说详情')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: snapshot.hasError
                  ? _DetailsErrorState(onRetry: _retry)
                  : const _DetailsLoadingState(),
            ),
          ),
        );
      },
    );
  }
}

class _DetailsLoadingState extends StatelessWidget {
  const _DetailsLoadingState();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('novel-details-loading'),
      liveRegion: true,
      label: '正在加载小说详情',
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在加载小说详情…'),
        ],
      ),
    );
  }
}

class _DetailsErrorState extends StatelessWidget {
  const _DetailsErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('novel-details-error'),
      liveRegion: true,
      label: '小说详情加载失败',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 44,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 14),
          Text('无法加载小说详情', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 7),
          const Text('已保留目录中的信息，可以稍后重试。'),
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const ValueKey('retry-novel-details'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
