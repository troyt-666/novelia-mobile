import 'dart:async';

import 'package:flutter/material.dart';

import '../../gateway/novelia/novelia_gateway.dart';
import '../../gateway/novelia/novelia_wenku_gateway.dart';
import 'wenku_epub_document.dart';
import 'wenku_epub_store.dart';
import 'wenku_reader_screen.dart';

class WenkuDetailsScreen extends StatefulWidget {
  const WenkuDetailsScreen({
    required this.gateway,
    required this.summary,
    this.store = const WenkuEpubStore(),
    super.key,
  });

  final NoveliaWenkuGateway gateway;
  final WenkuNovelSummary summary;
  final WenkuEpubStore store;

  @override
  State<WenkuDetailsScreen> createState() => _WenkuDetailsScreenState();
}

class _WenkuDetailsScreenState extends State<WenkuDetailsScreen> {
  WenkuNovelDetails? _novel;
  Object? _failure;
  var _loading = true;
  String? _activeVolumeId;
  var _bytesReceived = 0;
  int? _totalBytes;
  var _order = WenkuBilingualOrder.chineseFirst;
  WenkuEpubDownloadCancellationToken? _downloadCancellation;
  var _checkingCache = false;
  var _cancellingDownload = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _downloadCancellation?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final novel = await widget.gateway.getNovel(widget.summary.id);
      if (mounted) setState(() => _novel = novel);
    } on Object catch (error) {
      if (mounted) setState(() => _failure = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download(WenkuEpubVolume volume) async {
    final providers = volume.availableProviders;
    if (providers.isEmpty || _activeVolumeId != null) return;
    setState(() {
      _activeVolumeId = volume.volumeId;
      _bytesReceived = 0;
      _totalBytes = null;
      _checkingCache = true;
      _cancellingDownload = false;
    });
    final request = WenkuEpubRequest(
      novelId: widget.summary.id,
      volumeId: volume.volumeId,
      order: _order,
      providers: providers,
      filename: volume.volumeId,
    );
    WenkuEpubDownloadCancellationToken? cancellation;
    try {
      final cachedDocument = await widget.store.load(request);
      if (!mounted) return;
      if (cachedDocument != null) {
        await _openReader(cachedDocument, order: request.order);
        return;
      }

      final downloadCancellation = WenkuEpubDownloadCancellationToken();
      cancellation = downloadCancellation;
      setState(() {
        _checkingCache = false;
        _downloadCancellation = downloadCancellation;
      });
      final bytes = await widget.gateway.downloadEpub(
        request,
        onReceiveProgress: (received, total) {
          if (mounted &&
              identical(_downloadCancellation, downloadCancellation)) {
            setState(() {
              _bytesReceived = received;
              _totalBytes = total;
            });
          }
        },
        cancellationToken: downloadCancellation,
      );
      downloadCancellation.throwIfCancelled();
      final saved = await widget.store.save(request, bytes);
      downloadCancellation.throwIfCancelled();
      if (!mounted) return;
      await _openReader(saved.document, order: request.order);
    } on WenkuEpubDownloadCancelledException {
      // Cancellation is an expected user action, not a failed download.
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_messageFor(error))));
    } finally {
      if (mounted &&
          (_downloadCancellation == null ||
              identical(_downloadCancellation, cancellation))) {
        setState(() {
          _activeVolumeId = null;
          _downloadCancellation = null;
          _checkingCache = false;
          _cancellingDownload = false;
        });
      }
    }
  }

  Future<void> _openReader(
    WenkuEpubDocument document, {
    required WenkuBilingualOrder order,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => WenkuReaderScreen(
        document: document,
        title: _novel?.chineseTitle ?? widget.summary.chineseTitle,
        order: order,
      ),
      settings: RouteSettings(name: '/wenku/${widget.summary.id}/reader'),
    ),
  );

  void _cancelDownload() {
    final cancellation = _downloadCancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    cancellation.cancel();
    setState(() => _cancellingDownload = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('文库小说')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failure != null
          ? _FailureView(message: _messageFor(_failure!), onRetry: _load)
          : _buildDetails(_novel!),
    );
  }

  Widget _buildDetails(WenkuNovelDetails novel) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(uri: novel.coverUri),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    novel.chineseTitle,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    novel.japaneseTitle,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(novel.authors.join('、')),
                  if (novel.publisher != null) Text(novel.publisher!),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          novel.introduction,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.65),
        ),
        const SizedBox(height: 24),
        Text(
          '阅读设置',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        SegmentedButton<WenkuBilingualOrder>(
          segments: [
            for (final order in WenkuBilingualOrder.values)
              ButtonSegment(value: order, label: Text(order.label)),
          ],
          selected: {_order},
          onSelectionChanged: _activeVolumeId != null
              ? null
              : (selection) => setState(() => _order = selection.single),
        ),
        const SizedBox(height: 26),
        Text(
          '可读 EPUB',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          '翻译按 Sakura → GPT → 有道 → 百度的优先级补齐，日文原文始终保留。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        if (novel.japaneseEpubs.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Text('暂无可读的日文 EPUB。'),
            ),
          )
        else
          for (final volume in novel.japaneseEpubs) _volumeCard(volume),
      ],
    );
  }

  Widget _volumeCard(WenkuEpubVolume volume) {
    final active = _activeVolumeId == volume.volumeId;
    final total = _totalBytes;
    final progress = active && total != null && total > 0
        ? (_bytesReceived / total).clamp(0, 1).toDouble()
        : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              volume.volumeId,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final provider in volume.availableProviders)
                  Chip(
                    label: Text(
                      '${provider.label} ${(volume.coverageRatioFor(provider) * 100).round()}%',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (active) ...[
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _checkingCache
                          ? '正在检查本地 EPUB…'
                          : _cancellingDownload
                          ? '正在停止下载…'
                          : _downloadLabel(_bytesReceived, total),
                    ),
                  ),
                  if (_downloadCancellation != null)
                    TextButton.icon(
                      key: const ValueKey('wenku-stop-download-button'),
                      onPressed: _cancellingDownload ? null : _cancelDownload,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('停止'),
                    ),
                ],
              ),
            ] else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed:
                      volume.availableProviders.isEmpty ||
                          _activeVolumeId != null
                      ? null
                      : () => _download(volume),
                  icon: const Icon(Icons.download_for_offline_outlined),
                  label: const Text('下载并阅读'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _downloadLabel(int received, int? total) {
    String size(int bytes) =>
        '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return total == null
        ? '已下载 ${size(received)}'
        : '${size(received)} / ${size(total)}';
  }

  static String _messageFor(Object error) {
    if (error is NoveliaGatewayException) return error.message;
    return '文库内容载入失败，请稍后重试。';
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.uri});

  final Uri? uri;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.auto_stories_outlined, size: 38)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 104,
        height: 148,
        child: uri == null
            ? placeholder
            : Image.network(
                uri.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 44),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}
