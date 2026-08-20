import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/offline/offline_models.dart';
import '../discover/catalog_models.dart';
import 'shell_view_models.dart';

enum DownloadManagementAction { pause, resume, retry, remove }

typedef DownloadManagementHandler =
    Future<LibraryProtectedDownload?> Function(
      DownloadManagementAction action,
      LibraryProtectedDownload download,
    );

typedef DownloadManagementSnapshotLoader =
    FutureOr<List<LibraryProtectedDownload>> Function();

class DownloadManagementScreen extends StatefulWidget {
  const DownloadManagementScreen({
    required this.downloads,
    required this.onAction,
    required this.onOpenNovel,
    this.snapshotLoader,
    this.refreshInterval = const Duration(milliseconds: 400),
    super.key,
  }) : assert(refreshInterval > Duration.zero);

  final List<LibraryProtectedDownload> downloads;
  final DownloadManagementHandler onAction;
  final ValueChanged<CatalogNovel> onOpenNovel;
  final DownloadManagementSnapshotLoader? snapshotLoader;
  final Duration refreshInterval;

  @override
  State<DownloadManagementScreen> createState() =>
      _DownloadManagementScreenState();
}

class _DownloadManagementScreenState extends State<DownloadManagementScreen> {
  late List<LibraryProtectedDownload> _downloads;
  late String _downloadSignature;
  final Set<String> _busyGroups = <String>{};
  Timer? _refreshTimer;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _downloads = List.of(widget.downloads);
    _downloadSignature = _signature(_downloads);
    if (widget.snapshotLoader != null) {
      unawaited(_refreshDownloads());
      _refreshTimer = Timer.periodic(
        widget.refreshInterval,
        (_) => unawaited(_refreshDownloads()),
      );
    }
  }

  @override
  void didUpdateWidget(covariant DownloadManagementScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.snapshotLoader == null) {
      _replaceDownloads(widget.downloads);
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshDownloads() async {
    final loader = widget.snapshotLoader;
    if (loader == null || _refreshing) return;
    _refreshing = true;
    try {
      final latest = await Future<List<LibraryProtectedDownload>>.sync(loader);
      if (mounted) _replaceDownloads(latest);
    } on Object {
      // Keep the last truthful snapshot. Actions surface their own failures.
    } finally {
      _refreshing = false;
    }
  }

  void _replaceDownloads(List<LibraryProtectedDownload> latest) {
    final signature = _signature(latest);
    if (signature == _downloadSignature) return;
    setState(() {
      _downloads = List.of(latest);
      _downloadSignature = signature;
      _busyGroups.removeWhere(
        (key) => !_downloads.any((download) => download.groupKey == key),
      );
    });
  }

  static String _signature(Iterable<LibraryProtectedDownload> downloads) {
    return [
      for (final download in downloads) ...[
        download.groupKey,
        '${download.enabled}',
        ...download.intentIds,
        for (final chapter in download.chapters)
          [
            chapter.chapterId,
            chapter.taskState.name,
            '${chapter.byteCount}',
            '${chapter.bytesReceived}',
            '${chapter.totalBytes}',
            '${chapter.translationAvailable}',
            chapter.failure?.kind.name ?? '',
            chapter.failure?.message ?? '',
          ].join(':'),
      ],
    ].join('|');
  }

  Future<void> _run(
    DownloadManagementAction action,
    LibraryProtectedDownload download,
  ) async {
    final key = download.groupKey;
    if (!_busyGroups.add(key)) return;
    setState(() {});
    try {
      final updated = await widget.onAction(action, download);
      if (!mounted) return;
      setState(() {
        final index = _downloads.indexWhere((item) => item.groupKey == key);
        if (index < 0) return;
        if (updated == null) {
          _downloads.removeAt(index);
        } else {
          _downloads[index] = updated;
        }
        _downloadSignature = _signature(_downloads);
      });
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('下载操作失败，请稍后重试')));
    } finally {
      if (mounted) setState(() => _busyGroups.remove(key));
    }
  }

  Future<void> _confirmRemove(LibraryProtectedDownload download) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除离线下载？'),
        content: Text(
          '将删除《${download.novel.chineseTitle}》的 '
          '${download.translationSource.label} 离线内容。阅读进度和书签会保留。',
        ),
        actions: [
          TextButton(
            key: const ValueKey('cancel-remove-download'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-remove-download'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(DownloadManagementAction.remove, download);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('downloads-management-screen'),
      appBar: AppBar(title: const Text('管理离线下载')),
      body: _downloads.isEmpty
          ? const Center(
              child: Text(
                '还没有离线下载',
                key: ValueKey('downloads-management-empty'),
              ),
            )
          : RefreshIndicator(
              onRefresh: _refreshDownloads,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                itemCount: _downloads.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final download = _downloads[index];
                  final busy = _busyGroups.contains(download.groupKey);
                  return _ManagedDownloadCard(
                    download: download,
                    busy: busy,
                    onOpen: () => widget.onOpenNovel(download.novel),
                    onPause: () => unawaited(
                      _run(DownloadManagementAction.pause, download),
                    ),
                    onResume: () => unawaited(
                      _run(DownloadManagementAction.resume, download),
                    ),
                    onRetry: () => unawaited(
                      _run(DownloadManagementAction.retry, download),
                    ),
                    onRemove: () => unawaited(_confirmRemove(download)),
                  );
                },
              ),
            ),
    );
  }
}

class _ManagedDownloadCard extends StatelessWidget {
  const _ManagedDownloadCard({
    required this.download,
    required this.busy,
    required this.onOpen,
    required this.onPause,
    required this.onResume,
    required this.onRetry,
    required this.onRemove,
  });

  final LibraryProtectedDownload download;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final failures = download.chapters
        .where((chapter) => chapter.taskState == DownloadTaskState.failed)
        .toList(growable: false);
    final progress = download.progressFraction;
    final activeChapter = _currentChapter(download);
    final colors = Theme.of(context).colorScheme;
    return Card.outlined(
      key: ValueKey('managed-download-${download.groupKey}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              key: ValueKey('open-managed-download-${download.groupKey}'),
              onTap: busy ? null : onOpen,
              child: Row(
                children: [
                  CircleAvatar(child: Icon(_statusIcon(download))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          download.novel.chineseTitle,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(libraryDownloadSummary(download)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _DownloadStatusBadge(download: download),
                const Spacer(),
                Text(
                  download.chapters.isEmpty
                      ? '正在准备章节列表…'
                      : '${download.completedChapterCount} / '
                            '${download.chapters.length} 章 · '
                            '${((progress ?? 0) * 100).round()}%',
                  key: ValueKey('download-progress-label-${download.groupKey}'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              key: ValueKey('download-progress-${download.groupKey}'),
              value: progress,
              minHeight: 7,
              borderRadius: BorderRadius.circular(8),
            ),
            if (activeChapter != null) ...[
              const SizedBox(height: 9),
              Text(
                '${activeChapter.chapterId} · '
                '${_phaseLabel(activeChapter)}${_byteLabel(activeChapter)}',
                key: ValueKey('download-current-${download.groupKey}'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
            if (failures.isNotEmpty) ...[
              const SizedBox(height: 14),
              for (final chapter in failures)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${chapter.chapterId}：${_failureLabel(chapter.failure)}',
                    key: ValueKey(
                      'download-failure-${download.groupKey}-${chapter.chapterId}',
                    ),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 14),
            if (busy) ...[
              const Row(
                children: [
                  SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('正在更新下载任务…'),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (download.enabled && !download.isComplete)
                  OutlinedButton.icon(
                    key: ValueKey('pause-download-${download.groupKey}'),
                    onPressed: busy ? null : onPause,
                    icon: const Icon(Icons.pause),
                    label: const Text('暂停'),
                  )
                else if (!download.enabled && !download.isComplete)
                  FilledButton.tonalIcon(
                    key: ValueKey('resume-download-${download.groupKey}'),
                    onPressed: busy ? null : onResume,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('继续'),
                  ),
                if (download.retryableFailureCount > 0)
                  FilledButton.tonalIcon(
                    key: ValueKey('retry-download-${download.groupKey}'),
                    onPressed: busy ? null : onRetry,
                    icon: const Icon(Icons.refresh),
                    label: Text('重试 ${download.retryableFailureCount} 章'),
                  ),
                TextButton.icon(
                  key: ValueKey('remove-download-${download.groupKey}'),
                  onPressed: busy ? null : onRemove,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static LibraryDownloadChapter? _currentChapter(
    LibraryProtectedDownload download,
  ) {
    for (final chapter in download.chapters) {
      if (const {
        DownloadTaskState.fetching,
        DownloadTaskState.validating,
        DownloadTaskState.storing,
      }.contains(chapter.taskState)) {
        return chapter;
      }
    }
    for (final chapter in download.chapters) {
      if (chapter.taskState == DownloadTaskState.queued) return chapter;
    }
    return null;
  }

  static IconData _statusIcon(LibraryProtectedDownload download) {
    if (download.isComplete) return Icons.offline_pin;
    if (download.activeChapterCount > 0) return Icons.downloading;
    if (!download.enabled ||
        download.countWithState(DownloadTaskState.paused) > 0) {
      return Icons.pause_circle_outline;
    }
    if (download.countWithState(DownloadTaskState.failed) > 0) {
      return Icons.error_outline;
    }
    return Icons.schedule;
  }

  static String _phaseLabel(LibraryDownloadChapter chapter) {
    return switch (chapter.taskState) {
      DownloadTaskState.queued => '等待下载',
      DownloadTaskState.fetching => '正在下载',
      DownloadTaskState.validating => '正在校验',
      DownloadTaskState.storing => '正在保存',
      DownloadTaskState.paused => '已暂停',
      DownloadTaskState.failed => '下载失败',
      DownloadTaskState.stored => '已完成',
      DownloadTaskState.removed => '已删除',
    };
  }

  static String _byteLabel(LibraryDownloadChapter chapter) {
    final total = chapter.totalBytes;
    if (chapter.taskState != DownloadTaskState.fetching || total == null) {
      return '';
    }
    return ' · ${formatStorageBytes(chapter.bytesReceived)} / '
        '${formatStorageBytes(total)}';
  }

  static String _failureLabel(DownloadFailure? failure) {
    if (failure == null) return '下载失败';
    if (failure.kind == DownloadFailureKind.insufficientStorage) {
      final required = failure.requiredBytes;
      final available = failure.availableBytes;
      if (required != null && available != null) {
        return '存储空间不足（需要 ${formatStorageBytes(required)}，'
            '可用 ${formatStorageBytes(available)}）';
      }
      return '存储空间不足';
    }
    return switch (failure.kind) {
      DownloadFailureKind.network => '网络不可用，可重试',
      DownloadFailureKind.validation => '内容校验失败',
      DownloadFailureKind.unavailable => '来源内容不可用',
      DownloadFailureKind.schema => '内容格式暂不兼容',
      DownloadFailureKind.unknown => failure.message,
      DownloadFailureKind.insufficientStorage => '存储空间不足',
    };
  }
}

class _DownloadStatusBadge extends StatelessWidget {
  const _DownloadStatusBadge({required this.download});

  final LibraryProtectedDownload download;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (label, background, foreground) = _appearance(colors);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(
          label,
          key: ValueKey('download-status-${download.groupKey}'),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  (String, Color, Color) _appearance(ColorScheme colors) {
    if (download.isComplete) {
      return ('已完成', colors.tertiaryContainer, colors.onTertiaryContainer);
    }
    if (download.activeChapterCount > 0) {
      return ('下载中', colors.primaryContainer, colors.onPrimaryContainer);
    }
    if (!download.enabled ||
        download.countWithState(DownloadTaskState.paused) > 0) {
      return ('已暂停', colors.secondaryContainer, colors.onSecondaryContainer);
    }
    if (download.countWithState(DownloadTaskState.failed) > 0) {
      return ('需要处理', colors.errorContainer, colors.onErrorContainer);
    }
    return ('等待中', colors.surfaceContainerHighest, colors.onSurfaceVariant);
  }
}
