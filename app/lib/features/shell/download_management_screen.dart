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

class DownloadManagementScreen extends StatefulWidget {
  const DownloadManagementScreen({
    required this.downloads,
    required this.onAction,
    required this.onOpenNovel,
    super.key,
  });

  final List<LibraryProtectedDownload> downloads;
  final DownloadManagementHandler onAction;
  final ValueChanged<CatalogNovel> onOpenNovel;

  @override
  State<DownloadManagementScreen> createState() =>
      _DownloadManagementScreenState();
}

class _DownloadManagementScreenState extends State<DownloadManagementScreen> {
  late final List<LibraryProtectedDownload> _downloads = List.of(
    widget.downloads,
  );
  final Set<String> _busyGroups = <String>{};

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
          : ListView.separated(
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
                  onPause: () =>
                      unawaited(_run(DownloadManagementAction.pause, download)),
                  onResume: () => unawaited(
                    _run(DownloadManagementAction.resume, download),
                  ),
                  onRetry: () =>
                      unawaited(_run(DownloadManagementAction.retry, download)),
                  onRemove: () => unawaited(_confirmRemove(download)),
                );
              },
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
                  const CircleAvatar(child: Icon(Icons.offline_pin_outlined)),
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
            if (busy)
              const LinearProgressIndicator()
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (download.enabled)
                    OutlinedButton.icon(
                      key: ValueKey('pause-download-${download.groupKey}'),
                      onPressed: onPause,
                      icon: const Icon(Icons.pause),
                      label: const Text('暂停'),
                    )
                  else
                    FilledButton.tonalIcon(
                      key: ValueKey('resume-download-${download.groupKey}'),
                      onPressed: onResume,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('继续'),
                    ),
                  if (download.retryableFailureCount > 0)
                    FilledButton.tonalIcon(
                      key: ValueKey('retry-download-${download.groupKey}'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: Text('重试 ${download.retryableFailureCount} 章'),
                    ),
                  TextButton.icon(
                    key: ValueKey('remove-download-${download.groupKey}'),
                    onPressed: onRemove,
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
