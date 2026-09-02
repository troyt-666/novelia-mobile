import 'package:flutter/material.dart';

import '../discover/catalog_models.dart';

typedef LoadedReaderBuilder =
    Widget Function(BuildContext context, ReaderLaunchData data);

class ReaderLaunchLoaderScreen extends StatefulWidget {
  const ReaderLaunchLoaderScreen({
    required this.load,
    required this.builder,
    required this.onLoaded,
    super.key,
  });

  final Future<ReaderLaunchData> Function() load;
  final LoadedReaderBuilder builder;
  final ValueChanged<ReaderLaunchData> onLoaded;

  @override
  State<ReaderLaunchLoaderScreen> createState() =>
      _ReaderLaunchLoaderScreenState();
}

class _ReaderLaunchLoaderScreenState extends State<ReaderLaunchLoaderScreen> {
  late Future<ReaderLaunchData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<ReaderLaunchData> _load() async {
    final data = await widget.load();
    if (mounted) widget.onLoaded(data);
    return data;
  }

  void _retry() => setState(() {
    _future = _load();
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReaderLaunchData>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data != null) {
          return KeyedSubtree(
            key: const ValueKey('reader-launch-ready'),
            child: widget.builder(context, data),
          );
        }
        return Scaffold(
          key: const ValueKey('reader-launch-loader-screen'),
          appBar: AppBar(),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: snapshot.hasError
                  ? _ReaderErrorState(onRetry: _retry)
                  : const _ReaderLoadingState(),
            ),
          ),
        );
      },
    );
  }
}

class _ReaderLoadingState extends StatelessWidget {
  const _ReaderLoadingState();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('reader-launch-loading'),
      liveRegion: true,
      label: '正在准备阅读内容',
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在准备当前章节…'),
        ],
      ),
    );
  }
}

class _ReaderErrorState extends StatelessWidget {
  const _ReaderErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('reader-launch-error'),
      liveRegion: true,
      label: '阅读内容加载失败',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 44,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 14),
          Text('无法打开章节', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 7),
          const Text('未丢失当前位置，请检查网络后重试。'),
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const ValueKey('retry-reader-launch'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
