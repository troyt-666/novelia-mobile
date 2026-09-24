import 'dart:async';

import 'package:flutter/material.dart';

import '../../gateway/novelia/novelia_wenku_gateway.dart';
import 'wenku_epub_store.dart';
import 'wenku_reader_screen.dart';

class WenkuDownloadsButton extends StatelessWidget {
  const WenkuDownloadsButton({required this.store, super.key});

  final WenkuEpubStore store;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const ValueKey('wenku-downloads-button'),
    onPressed: () => Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => WenkuDownloadsScreen(store: store),
        settings: const RouteSettings(name: '/wenku/downloads'),
      ),
    ),
    icon: const Icon(Icons.offline_pin_outlined),
    label: const Text('已下载'),
  );
}

/// This route intentionally has no gateway: opening a download is local only.
class WenkuDownloadsScreen extends StatefulWidget {
  const WenkuDownloadsScreen({required this.store, super.key});

  final WenkuEpubStore store;

  @override
  State<WenkuDownloadsScreen> createState() => _WenkuDownloadsScreenState();
}

class _WenkuDownloadsScreenState extends State<WenkuDownloadsScreen> {
  List<WenkuDownloadedEpub> _downloads = const [];
  var _loading = true;
  var _failed = false;
  String? _opening;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final downloads = await widget.store.listDownloads();
      if (mounted) setState(() => _downloads = downloads);
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(WenkuDownloadedEpub download) async {
    if (_opening != null) return;
    setState(() => _opening = download.fileName);
    try {
      final document = await widget.store.openDownload(download);
      final position = await widget.store.readingPosition(download.fileName);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => WenkuReaderScreen(
            document: document,
            title: download.title,
            order: download.order,
            initialPosition: position,
            onPositionChanged: (position) =>
                widget.store.saveReadingPosition(download.fileName, position),
          ),
          settings: RouteSettings(
            name: '/wenku/downloads/${download.fileName}',
          ),
        ),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地 EPUB 无法打开，文件可能已损坏或被移除。')),
      );
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('已下载文库')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _failed
        ? Center(
            child: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('本地下载读取失败，点击重试'),
            ),
          )
        : RefreshIndicator(
            onRefresh: _load,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (_downloads.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('暂无已下载文库，下载后的 EPUB 可在这里离线阅读。')),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
                    sliver: SliverList.separated(
                      itemCount: _downloads.length,
                      separatorBuilder: (_, _) => const Divider(),
                      itemBuilder: (context, index) {
                        final download = _downloads[index];
                        return ListTile(
                          key: ValueKey('wenku-download-${download.fileName}'),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 8,
                          ),
                          leading: const Icon(Icons.offline_pin_outlined),
                          title: Text(download.title),
                          subtitle: Text(
                            [
                              if (download.volumeId != null) download.volumeId!,
                              download.order?.label ?? '保留文件原有顺序',
                            ].join(' · '),
                          ),
                          trailing: _opening == download.fileName
                              ? const SizedBox.square(
                                  dimension: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.chevron_right),
                          onTap: _opening == null
                              ? () => _open(download)
                              : null,
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
  );
}
