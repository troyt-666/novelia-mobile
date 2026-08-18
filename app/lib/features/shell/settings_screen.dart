import 'package:flutter/material.dart';

import '../../core/account/account_models.dart';
import '../../core/offline/offline_models.dart';
import '../account/account_screen.dart';
import 'shell_view_models.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.onClearSearchHistory,
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
    super.key,
  }) : assert(cacheLimitBytes == null || cacheLimitBytes >= 0);

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final VoidCallback onClearSearchHistory;
  final OfflineStorageSummary storageSummary;

  /// Null means that no cache limit is currently configured.
  final int? cacheLimitBytes;
  final AccountSessionSnapshot accountSession;
  final AccountLogin? onAccountLogin;
  final Future<void> Function()? onAccountLogout;
  final VoidCallback? onHostedAccountHelp;
  final VoidCallback? onLoginRequested;
  final VoidCallback? onReleasesRequested;

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
                trailing: const Icon(Icons.chevron_right),
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
                trailing: const Icon(Icons.chevron_right),
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('clear-search-history-button'),
                leading: const Icon(Icons.manage_search),
                title: const Text('清除搜索历史'),
                onTap: onClearSearchHistory,
              ),
              const Divider(height: 1),
              const ListTile(
                leading: Icon(Icons.bug_report_outlined),
                title: Text('导出诊断信息'),
                subtitle: Text('不包含章节文本、令牌或账号标识'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SettingsSection(
            title: '关于',
            children: [
              ListTile(
                key: const ValueKey('open-releases-button'),
                leading: const Icon(Icons.new_releases_outlined),
                title: const Text('版本与更新'),
                subtitle: const Text('0.1.0 · 手动安装测试版'),
                trailing: const Icon(Icons.open_in_new),
                onTap: onReleasesRequested,
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
