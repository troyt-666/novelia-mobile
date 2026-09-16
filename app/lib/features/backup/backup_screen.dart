import 'package:flutter/material.dart';

import '../../core/backup/backup_files.dart';
import '../../core/backup/reader_backup.dart';
import '../../core/database/sqlite_offline_repository.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({
    required this.repository,
    required this.onImported,
    this.files = const SystemBackupFiles(),
    super.key,
  });

  final SqliteOfflineRepository repository;
  final VoidCallback onImported;
  final BackupFiles files;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _scroll = ScrollController();
  var _includeContent = false;
  var _importSettings = false;
  var _busy = false;
  String? _status;
  String? _error;
  BackupPreview? _preview;
  final _choices = <String, ProgressChoice>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _run(String status, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = status;
      _error = null;
    });
    // Let the busy state paint before taking a consistent local snapshot.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    try {
      await action();
    } on BackupException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _status = null;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _error = '未能完成操作，请检查文件和可用空间后重试。';
          _status = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted) _scrollToTop();
    }
  }

  Future<void> _export() => _run('正在准备备份…', () async {
    final backup = widget.repository.exportBackup(
      includeContent: _includeContent,
    );
    final saved = await widget.files.save(backup);
    if (mounted) setState(() => _status = saved ? '备份已保存' : null);
  });

  Future<void> _open() => _run('正在读取备份…', () async {
    final backup = await widget.files.open();
    if (!mounted) return;
    if (backup == null) {
      setState(() => _status = null);
      return;
    }
    _showPreview(backup);
  });

  void _showPreview(ReaderBackup backup) {
    final preview = widget.repository.previewBackup(backup);
    setState(() {
      _preview = preview;
      _choices.clear();
      _importSettings = false;
      _status = null;
    });
  }

  Future<void> _merge() => _run('正在合并…', () async {
    final result = widget.repository.mergeBackup(
      _preview!,
      choices: _choices,
      importSettings: _importSettings,
    );
    setState(() {
      _preview = null;
      _status =
          '合并完成：新增 ${result.newNovels} 本书、${result.bookmarksAdded} 个书签、'
          '${result.downloadsAdded} 条下载记录、${result.chaptersAdded} 章正文，'
          '更新 ${result.progressUpdated} 条进度。';
    });
    widget.onImported();
  });

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(preview == null ? '备份与恢复' : '导入预览')),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                controller: _scroll,
                key: const ValueKey('backup-scroll'),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  if (_busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                  ],
                  if (_status != null) ...[
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _status!,
                        key: const ValueKey('backup-status'),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (_error != null) ...[
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        key: const ValueKey('backup-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    if (preview != null)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                '正在重新预览…',
                                () async => _showPreview(preview.backup),
                              ),
                        child: const Text('重新预览'),
                      ),
                    const SizedBox(height: 20),
                  ],
                  if (preview == null)
                    ..._actions(context)
                  else
                    ..._review(context, preview),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) => [
    Text('导出备份', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 8),
    const Text('保存本机阅读进度、书签、下载记录、搜索历史和阅读设置。'),
    const SizedBox(height: 16),
    Card.outlined(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        key: const ValueKey('backup-include-content'),
        title: const Text('包含离线正文'),
        subtitle: const Text('加入已下载的网文章节和译文，文件会更大'),
        value: _includeContent,
        onChanged: _busy
            ? null
            : (value) => setState(() => _includeContent = value),
      ),
    ),
    const SizedBox(height: 12),
    FilledButton.icon(
      key: const ValueKey('backup-export'),
      onPressed: _busy ? null : _export,
      icon: const Icon(Icons.save_alt),
      label: const Text('导出备份'),
    ),
    const SizedBox(height: 32),
    Text('导入备份', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 8),
    const Text('选择备份后，先查看将要合并的记录。同一本书的进度可以逐本选择。'),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      key: const ValueKey('backup-import'),
      onPressed: _busy ? null : _open,
      icon: const Icon(Icons.upload_file_outlined),
      label: const Text('选择备份文件'),
    ),
    const SizedBox(height: 24),
    Text(
      '备份不含登录信息、云端收藏和阅读缓存。换机后需重新登录。',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  ];

  List<Widget> _review(BuildContext context, BackupPreview preview) => [
    Text(
      '备份于 ${_date(preview.backup.createdAt)}',
      style: Theme.of(context).textTheme.titleMedium,
    ),
    const SizedBox(height: 8),
    Text(
      '${preview.backup.novelCount} 本书 · ${preview.backup.progressCount} 条进度 · ${preview.backup.bookmarkCount} 个书签'
      ' · ${preview.backup.downloadCount} 条下载记录 · ${preview.backup.chapterCount} 章正文',
    ),
    const SizedBox(height: 16),
    Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '备份中的记录将新增 ${preview.newNovels} 本书、${preview.newProgress} 条进度、'
          '${preview.newBookmarks} 个书签、${preview.newDownloads} 条下载记录、${preview.newChapters} 章正文。'
          '\n已有书签会去重；已有正文保留，只补缺少的章节和译源。'
          '${preview.conflicts.isEmpty ? '' : '\n未选的进度位置另存为书签。'}',
        ),
      ),
    ),
    const SizedBox(height: 24),
    if (preview.conflicts.isNotEmpty) ...[
      Text(
        '${preview.conflicts.length} 本书的进度不同',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      const Text('默认选最近阅读的位置；时间相同则保留本机。另一处位置会存成书签。'),
      const SizedBox(height: 16),
      for (final conflict in preview.conflicts) ...[
        Card.outlined(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    conflict.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 8),
                for (final choice in ProgressChoice.values)
                  RadioListTile<ProgressChoice>(
                    key: ValueKey(
                      'backup-choice-${conflict.novelId}-${choice.name}',
                    ),
                    value: choice,
                    // Compatible with the HarmonyOS Flutter SDK as well as stable.
                    // ignore: deprecated_member_use
                    groupValue:
                        _choices[conflict.novelId] ?? conflict.recommended,
                    // ignore: deprecated_member_use
                    onChanged: _busy
                        ? null
                        : (value) => setState(
                            () => _choices[conflict.novelId] = value!,
                          ),
                    title: Text(choice == ProgressChoice.local ? '本机' : '备份'),
                    subtitle: Text(
                      '${choice == ProgressChoice.local ? conflict.localPosition : conflict.importedPosition}\n'
                      '${_date(choice == ProgressChoice.local ? conflict.localTime : conflict.importedTime)}',
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    ],
    if (preview.backup.rows('app_settings').isNotEmpty)
      CheckboxListTile(
        key: const ValueKey('backup-import-settings'),
        contentPadding: EdgeInsets.zero,
        title: const Text('同时使用备份中的阅读设置'),
        subtitle: const Text('包括主题、字号和排版'),
        value: _importSettings,
        onChanged: _busy
            ? null
            : (value) => setState(() => _importSettings = value!),
      ),
    const SizedBox(height: 8),
    const Text('合并会保留本机原有记录。导入的下载任务保持暂停，可在下载管理中继续。'),
    const SizedBox(height: 20),
    FilledButton(
      key: const ValueKey('backup-merge'),
      onPressed: _busy ? null : _merge,
      child: const Text('确认合并'),
    ),
    const SizedBox(height: 8),
    TextButton(
      key: const ValueKey('backup-cancel'),
      onPressed: _busy
          ? null
          : () {
              setState(() {
                _preview = null;
                _error = null;
                _status = null;
              });
              _scrollToTop();
            },
      child: const Text('取消'),
    ),
  ];
}

String _date(DateTime value) {
  final date = value.toLocal();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
}
