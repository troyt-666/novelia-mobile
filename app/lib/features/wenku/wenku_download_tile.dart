import 'package:flutter/material.dart';

import '../shell/shell_view_models.dart';
import 'wenku_epub_store.dart';
import 'wenku_reader_screen.dart';

class WenkuDownloadTile extends StatefulWidget {
  const WenkuDownloadTile({
    required this.store,
    required this.download,
    required this.onChanged,
    this.manage = false,
    super.key,
  });
  final WenkuEpubStore store;
  final WenkuDownloadedEpub download;
  final VoidCallback onChanged;
  final bool manage;

  @override
  State<WenkuDownloadTile> createState() => _WenkuDownloadTileState();
}

class _WenkuDownloadTileState extends State<WenkuDownloadTile> {
  bool _busy = false;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作未完成，本地正文和阅读位置仍保留，请重试。')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() => _run(() async {
    final download = widget.download;
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
        settings: RouteSettings(name: '/wenku/downloads/${download.fileName}'),
      ),
    );
  });

  Future<void> _action(String action) => _run(() async {
    if (action == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('移除文库下载？'),
          content: Text('移除《${widget.download.title}》的 EPUB 文件和插图，保留阅读位置。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm-remove-wenku'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await widget.store.remove(widget.download);
    } else {
      final complete = await widget.store.repairImages(widget.download);
      if (mounted && !complete) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('仍有插图未下载，请检查网络后重试；正文可继续阅读。')),
        );
      }
    }
    widget.onChanged();
  });

  @override
  Widget build(BuildContext context) {
    final d = widget.download;
    return ListTile(
      key: ValueKey('wenku-download-${d.fileName}'),
      leading: const Icon(Icons.menu_book_outlined),
      title: Text(d.title),
      subtitle: Text(
        [
          '文库',
          if (d.volumeId != null) d.volumeId!,
          formatStorageBytes(d.byteCount),
          if (d.missingImages > 0) '${d.missingImages} 张插图待下载',
        ].join(' · '),
      ),
      onTap: _busy ? null : _open,
      trailing: _busy
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : widget.manage
          ? PopupMenuButton<String>(
              key: ValueKey('manage-wenku-${d.fileName}'),
              tooltip: '管理文库下载',
              onSelected: _action,
              itemBuilder: (_) => [
                if (d.missingImages > 0)
                  const PopupMenuItem(value: 'repair', child: Text('补全插图')),
                const PopupMenuItem(value: 'remove', child: Text('移除下载')),
              ],
            )
          : const Icon(Icons.chevron_right),
    );
  }
}
