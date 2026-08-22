import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/account/account_models.dart';
import '../../core/offline/offline_models.dart';
import '../../core/platform/app_update.dart';
import '../../core/platform/app_version.dart';
import '../account/account_screen.dart';
import 'shell_view_models.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.onClearSearchHistory,
    this.appVersion = const AppVersion.unavailable(),
    this.onManageOfflineDownloads,
    this.onCacheLimitChanged,
    this.onClearReadingCache,
    this.storageSummary = const OfflineStorageSummary(
      cacheBytes: 0,
      offlineDownloadBytes: 0,
      cacheChapterCount: 0,
      offlineDownloadChapterCount: 0,
      perNovel: [],
    ),
    this.cacheLimitBytes,
    this.accountSession = const AccountSessionSnapshot.signedOut(),
    this.onAccountLogin,
    this.onAccountLogout,
    this.onHostedAccountHelp,
    this.onLoginRequested,
    this.onReleasesRequested,
    this.onCheckForUpdate,
    this.onOpenUpdateLink,
    super.key,
  }) : assert(cacheLimitBytes == null || cacheLimitBytes >= 0);

  final ThemeMode themeMode;
  final AppVersion appVersion;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final VoidCallback onClearSearchHistory;
  final VoidCallback? onManageOfflineDownloads;
  final ValueChanged<int>? onCacheLimitChanged;
  final FutureOr<int> Function()? onClearReadingCache;
  final OfflineStorageSummary storageSummary;

  /// Null means that no cache limit is currently configured.
  final int? cacheLimitBytes;
  final AccountSessionSnapshot accountSession;
  final AccountLogin? onAccountLogin;
  final Future<void> Function()? onAccountLogout;
  final VoidCallback? onHostedAccountHelp;
  final VoidCallback? onLoginRequested;
  final VoidCallback? onReleasesRequested;
  final Future<AppUpdateCheck> Function()? onCheckForUpdate;
  final Future<void> Function(Uri uri)? onOpenUpdateLink;

  @override
  Widget build(BuildContext context) {
    final downloadedNovelCount = storageSummary.perNovel.where((novel) {
      return novel.offlineDownloadChapterCount > 0;
    }).length;

    return SafeArea(
      bottom: false,
      child: ListView(
        key: const PageStorageKey('settings-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: [
          Text(
            '设置',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 24),
          _SettingsSection(
            title: '账号',
            children: [
              ListTile(
                key: const ValueKey('settings-account'),
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(_accountTitle(accountSession)),
                subtitle: Text(_accountSubtitle(accountSession)),
                trailing: _accountTrailing(context),
                onTap: accountSession.status == AccountSessionStatus.signedOut
                    ? () => _openAccount(context)
                    : accountSession.status == AccountSessionStatus.unavailable
                    ? onLoginRequested
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SettingsSection(
            title: '外观',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('主题'),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ThemeMode>(
                        key: const ValueKey('settings-theme-mode'),
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            icon: Icon(Icons.brightness_auto),
                            label: Text('跟随系统'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode_outlined),
                            label: Text('浅色'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode_outlined),
                            label: Text('深色'),
                          ),
                        ],
                        selected: {themeMode},
                        showSelectedIcon: false,
                        onSelectionChanged: (selection) {
                          if (selection.isNotEmpty) {
                            onThemeModeChanged(selection.first);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SettingsSection(
            title: '存储与隐私',
            children: [
              ListTile(
                key: const ValueKey('settings-offline-storage'),
                leading: const Icon(Icons.offline_pin_outlined),
                title: const Text('离线下载'),
                subtitle: Text(
                  '${formatStorageBytes(storageSummary.offlineDownloadBytes)}'
                  ' · $downloadedNovelCount 部小说'
                  ' · ${storageSummary.offlineDownloadChapterCount} 章',
                ),
                trailing: onManageOfflineDownloads == null
                    ? null
                    : const Icon(Icons.chevron_right),
                onTap: onManageOfflineDownloads,
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('settings-cache-storage'),
                leading: const Icon(Icons.cached),
                title: const Text('阅读缓存'),
                subtitle: Text(
                  '${formatStorageBytes(storageSummary.cacheBytes)}'
                  ' · ${storageSummary.cacheChapterCount} 章'
                  ' · ${_cacheLimitLabel(cacheLimitBytes)}',
                ),
                trailing: onClearReadingCache == null
                    ? null
                    : const Icon(Icons.chevron_right),
                onTap: onClearReadingCache == null
                    ? null
                    : () => _showCacheManager(context),
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('clear-search-history-button'),
                leading: const Icon(Icons.manage_search),
                title: const Text('清除搜索历史'),
                onTap: onClearSearchHistory,
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('export-diagnostics-button'),
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('导出诊断信息'),
                subtitle: const Text('不包含章节文本、令牌或账号标识'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showDiagnostics(context),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SettingsSection(
            title: '关于',
            children: [
              _UpdateTile(
                appVersion: appVersion,
                onCheckForUpdate: onCheckForUpdate,
                onOpenUpdateLink: onOpenUpdateLink,
                onReleasesRequested: onReleasesRequested,
              ),
              const Divider(height: 1),
              const ListTile(
                leading: Icon(Icons.translate),
                title: Text('界面语言'),
                subtitle: Text('简体中文'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _cacheLimitLabel(int? cacheLimitBytes) {
    if (cacheLimitBytes == null) return '上限未设置';
    return '上限 ${formatStorageBytes(cacheLimitBytes)}';
  }

  Future<void> _showCacheManager(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final limit = cacheLimitBytes;
    final standardLimits = <int>{
      ?limit,
      64 * 1024 * 1024,
      128 * 1024 * 1024,
      256 * 1024 * 1024,
      512 * 1024 * 1024,
      1024 * 1024 * 1024,
    }.toList()..sort();
    var selectedLimit = limit;
    var clearing = false;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '阅读缓存',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text('缓存用于加快再次打开章节；清空后会在需要时重新获取，不会删除离线下载、阅读进度或书签。'),
                const SizedBox(height: 16),
                Text(
                  '当前 ${formatStorageBytes(storageSummary.cacheBytes)}'
                  ' · ${storageSummary.cacheChapterCount} 章',
                  key: const ValueKey('cache-management-summary'),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  key: const ValueKey('cache-limit-selector'),
                  initialValue: selectedLimit,
                  decoration: const InputDecoration(
                    labelText: '缓存上限',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final value in standardLimits)
                      DropdownMenuItem(
                        value: value,
                        child: Text(formatStorageBytes(value)),
                      ),
                  ],
                  onChanged: onCacheLimitChanged == null
                      ? null
                      : (value) {
                          if (value == null || value == selectedLimit) return;
                          setSheetState(() => selectedLimit = value);
                          onCacheLimitChanged!(value);
                          ScaffoldMessenger.of(sheetContext)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(
                              SnackBar(
                                content: Text(
                                  '缓存上限已设为 ${formatStorageBytes(value)}',
                                ),
                              ),
                            );
                        },
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const ValueKey('clear-reading-cache-button'),
                  onPressed: clearing
                      ? null
                      : () async {
                          setSheetState(() => clearing = true);
                          try {
                            final removed = await onClearReadingCache!();
                            if (!sheetContext.mounted) return;
                            Navigator.of(sheetContext).pop();
                            messenger
                              ..hideCurrentSnackBar()
                              ..showSnackBar(
                                SnackBar(
                                  content: Text(
                                    removed == 0
                                        ? '阅读缓存已经是空的'
                                        : '已清除 $removed 章阅读缓存',
                                  ),
                                ),
                              );
                          } finally {
                            if (sheetContext.mounted) {
                              setSheetState(() => clearing = false);
                            }
                          }
                        },
                  icon: clearing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_sweep_outlined),
                  label: const Text('清空阅读缓存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showDiagnostics(BuildContext context) async {
    final diagnostics = <String>[
      'JFZ Reader diagnostics',
      'generatedAt=${DateTime.now().toUtc().toIso8601String()}',
      'version=${appVersion.display}',
      'theme=${themeMode.name}',
      'accountState=${accountSession.status.name}',
      'offlineDownloadBytes=${storageSummary.offlineDownloadBytes}',
      'offlineDownloadChapters=${storageSummary.offlineDownloadChapterCount}',
      'cacheBytes=${storageSummary.cacheBytes}',
      'cacheChapters=${storageSummary.cacheChapterCount}',
      'cacheLimitBytes=${cacheLimitBytes ?? 'unknown'}',
    ].join('\n');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('诊断信息'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              diagnostics,
              key: const ValueKey('diagnostics-preview'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            key: const ValueKey('copy-diagnostics-button'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: diagnostics));
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('诊断信息已复制')));
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制'),
          ),
        ],
      ),
    );
  }

  Future<void> _openAccount(BuildContext context) async {
    final login = onAccountLogin;
    if (login == null) {
      onLoginRequested?.call();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AccountScreen(
          onLogin: login,
          onHostedAccountHelp: onHostedAccountHelp,
        ),
        settings: const RouteSettings(name: '/account/login'),
      ),
    );
  }

  String _accountTitle(AccountSessionSnapshot session) {
    final username = session.profile?.username;
    return username == null ? '未登录' : '@$username';
  }

  String _accountSubtitle(AccountSessionSnapshot session) {
    return switch (session.status) {
      AccountSessionStatus.signedOut => '登录后可使用远程收藏夹与阅读历史',
      AccountSessionStatus.restoring => '正在检查账号状态',
      AccountSessionStatus.signedIn => '已登录 · ${session.profile!.role}',
      AccountSessionStatus.unavailable =>
        session.message ?? '账号服务暂时不可用，本地阅读仍可使用',
    };
  }

  Widget _accountTrailing(BuildContext context) {
    if (accountSession.status == AccountSessionStatus.restoring) {
      return const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (accountSession.hasStoredAccount && onAccountLogout != null) {
      return IconButton(
        key: const ValueKey('account-logout-button'),
        tooltip: '退出登录',
        onPressed: () => _confirmLogout(context),
        icon: const Icon(Icons.logout),
      );
    }
    return const Icon(Icons.chevron_right);
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录？'),
        content: const Text('本机阅读进度、书签、缓存与离线下载会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-account-logout'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onAccountLogout?.call();
  }
}

class _UpdateTile extends StatefulWidget {
  const _UpdateTile({
    required this.appVersion,
    this.onCheckForUpdate,
    this.onOpenUpdateLink,
    this.onReleasesRequested,
  });

  final AppVersion appVersion;
  final Future<AppUpdateCheck> Function()? onCheckForUpdate;
  final Future<void> Function(Uri uri)? onOpenUpdateLink;
  final VoidCallback? onReleasesRequested;

  @override
  State<_UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends State<_UpdateTile> {
  AppUpdateCheck? _result;
  var _checking = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.onCheckForUpdate != null && widget.appVersion.name.isNotEmpty) {
      unawaited(_check());
    }
  }

  @override
  void didUpdateWidget(covariant _UpdateTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.onCheckForUpdate != widget.onCheckForUpdate ||
            oldWidget.appVersion.display != widget.appVersion.display) &&
        widget.onCheckForUpdate != null &&
        widget.appVersion.name.isNotEmpty) {
      unawaited(_check());
    }
  }

  String get _subtitle {
    if (_checking) return '${widget.appVersion.display} · 正在检查更新';
    final result = _result;
    if (result?.updateAvailable == true) {
      return '${widget.appVersion.display} · 新版本 ${result!.latestVersion.display}';
    }
    if (result != null) return '${widget.appVersion.display} · 已是最新版本';
    if (_failed) return '${widget.appVersion.display} · 无法检查，点击重试';
    return '${widget.appVersion.display} · 手动安装版';
  }

  Future<void> _check({bool showDetails = false}) async {
    final check = widget.onCheckForUpdate;
    if (check == null || _checking) return;
    setState(() {
      _checking = true;
      _failed = false;
    });
    try {
      final result = await check();
      if (!mounted) return;
      setState(() => _result = result);
      if (showDetails) await _showDetails(result);
    } on Object {
      if (!mounted) return;
      setState(() {
        _result = null;
        _failed = true;
      });
      if (showDetails) {
        final messenger = ScaffoldMessenger.of(context);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: const Text('暂时无法检查更新'),
              action: widget.onReleasesRequested == null
                  ? null
                  : SnackBarAction(
                      label: '发布页',
                      onPressed: widget.onReleasesRequested!,
                    ),
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _handleTap() async {
    final result = _result;
    if (result != null) {
      await _showDetails(result);
      return;
    }
    if (widget.onCheckForUpdate != null) {
      await _check(showDetails: true);
      return;
    }
    widget.onReleasesRequested?.call();
  }

  Future<void> _showDetails(AppUpdateCheck result) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                result.updateAvailable ? '发现新版本' : '已是最新版本',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                '已安装 ${result.installedVersion.display}'
                ' · 最新 ${result.latestVersion.display}',
              ),
              if (result.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  result.releaseNotes,
                  key: const ValueKey('update-release-notes'),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 18),
              if (result.updateAvailable &&
                  result.platform != AppUpdatePlatform.ios)
                FilledButton.icon(
                  key: const ValueKey('download-platform-update'),
                  onPressed: widget.onOpenUpdateLink == null
                      ? null
                      : () => widget.onOpenUpdateLink!(result.downloadUri),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(
                    result.platform == AppUpdatePlatform.android
                        ? '下载 Android APK'
                        : '下载 macOS DMG',
                  ),
                ),
              if (result.platform == AppUpdatePlatform.ios) ...[
                FilledButton.icon(
                  key: const ValueKey('copy-altstore-source'),
                  onPressed: () => _copyAltStoreSource(
                    sheetContext,
                    result.altStoreSourceUri,
                  ),
                  icon: const Icon(Icons.copy),
                  label: const Text('复制 AltStore 源地址'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('download-sideloadly-ipa'),
                  onPressed: widget.onOpenUpdateLink == null
                      ? null
                      : () => widget.onOpenUpdateLink!(result.downloadUri),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('下载 IPA（Sideloadly）'),
                ),
              ],
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('open-update-release-page'),
                onPressed: widget.onOpenUpdateLink == null
                    ? widget.onReleasesRequested
                    : () => widget.onOpenUpdateLink!(result.releasePageUri),
                icon: const Icon(Icons.open_in_new),
                label: const Text('查看 GitHub 发布页'),
              ),
              TextButton(
                key: const ValueKey('check-update-again'),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_check(showDetails: true));
                },
                child: const Text('重新检查'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyAltStoreSource(BuildContext context, Uri uri) async {
    await Clipboard.setData(ClipboardData(text: uri.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('AltStore 源地址已复制')));
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const ValueKey('open-releases-button'),
      leading: Icon(
        _result?.updateAvailable == true
            ? Icons.system_update_alt
            : Icons.new_releases_outlined,
      ),
      title: const Text('版本与更新'),
      subtitle: Text(_subtitle),
      trailing: _checking
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              _result?.updateAvailable == true
                  ? Icons.download_outlined
                  : Icons.chevron_right,
            ),
      onTap: _checking ? null : _handleTap,
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Card.outlined(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }
}
