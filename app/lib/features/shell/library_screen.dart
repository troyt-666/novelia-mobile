import 'package:flutter/material.dart';

import '../../core/model/reader_models.dart';
import '../../core/offline/offline_models.dart';
import '../discover/catalog_models.dart';
import 'shell_view_models.dart';

enum _LibrarySort { recent, title }

enum _DownloadFilter {
  all('全部'),
  complete('已完成'),
  incomplete('未完成'),
  failed('失败'),
  paused('暂停');

  const _DownloadFilter(this.label);
  final String label;

  bool matches(LibraryProtectedDownload download) => switch (this) {
    all => true,
    complete => download.isComplete,
    incomplete => !download.isComplete,
    failed => download.countWithState(DownloadTaskState.failed) > 0,
    paused =>
      !download.isComplete &&
          (!download.enabled ||
              download.countWithState(DownloadTaskState.paused) > 0),
  };
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    required this.onOpenNovel,
    this.onOpenPosition,
    this.onOpenDownload,
    this.continuedReads = const [],
    this.protectedDownloads = const [],
    this.bookmarks = const [],
    this.remoteFavorites = const RemoteFavoritesViewModel.unavailable(),
    this.isSignedIn,
    this.onSignInRequested,
    this.onFavoriteFolderRequested,
    this.onReadingHistoryRequested,
    this.onDownloadsManageRequested,
    super.key,
  });

  final ValueChanged<CatalogNovel> onOpenNovel;
  final void Function(CatalogNovel novel, ReadingPosition position)?
  onOpenPosition;
  final ValueChanged<LibraryProtectedDownload>? onOpenDownload;
  final List<LibraryContinuedRead> continuedReads;
  final List<LibraryProtectedDownload> protectedDownloads;
  final List<LibraryBookmarkItem> bookmarks;
  final RemoteFavoritesViewModel remoteFavorites;
  final bool? isSignedIn;
  final VoidCallback? onSignInRequested;
  final ValueChanged<LibraryFavoriteFolder>? onFavoriteFolderRequested;
  final VoidCallback? onReadingHistoryRequested;
  final VoidCallback? onDownloadsManageRequested;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _search = [TextEditingController(), TextEditingController()];
  final _scroll = List.generate(3, (_) => ScrollController());
  final _sort = [_LibrarySort.recent, _LibrarySort.recent];
  _DownloadFilter _filter = _DownloadFilter.all;

  @override
  void dispose() {
    for (final controller in _search) {
      controller.dispose();
    }
    for (final controller in _scroll) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changeResults(int tab, VoidCallback change) {
    setState(change);
    if (_scroll[tab].hasClients) _scroll[tab].jumpTo(0);
  }

  bool _matches(CatalogNovel novel, int tab) =>
      novel.chineseTitle.toLowerCase().contains(
        _search[tab].text.trim().toLowerCase(),
      ) ||
      novel.japaneseTitle.toLowerCase().contains(
        _search[tab].text.trim().toLowerCase(),
      );

  void _openBookmarks() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/library/bookmarks'),
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('书签')),
          body: widget.bookmarks.isEmpty
              ? const Center(child: _LibraryEmpty(message: '还没有书签'))
              : ListView.separated(
                  key: const PageStorageKey('library-bookmarks-scroll'),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  itemCount: widget.bookmarks.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final bookmark = widget.bookmarks[index];
                    return ListTile(
                      key: ValueKey('bookmark-${bookmark.id}'),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      leading: const Icon(Icons.bookmark_outline),
                      title: Text(bookmark.novel.chineseTitle),
                      subtitle: Text(
                        bookmark.chapterLabel ?? bookmark.position.chapterId,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => widget.onOpenPosition != null
                          ? widget.onOpenPosition!(
                              bookmark.novel,
                              bookmark.position,
                            )
                          : widget.onOpenNovel(bookmark.novel),
                    );
                  },
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reads = widget.continuedReads
        .where((item) => _matches(item.novel, 0))
        .toList();
    final downloads = widget.protectedDownloads
        .where((item) => _matches(item.novel, 1) && _filter.matches(item))
        .toList();
    if (_sort[0] == _LibrarySort.title) {
      reads.sort(
        (a, b) => a.novel.chineseTitle.compareTo(b.novel.chineseTitle),
      );
    }
    if (_sort[1] == _LibrarySort.title) {
      downloads.sort((a, b) {
        final title = a.novel.chineseTitle.compareTo(b.novel.chineseTitle);
        return title == 0 ? a.groupKey.compareTo(b.groupKey) : title;
      });
    }

    return SafeArea(
      bottom: false,
      child: DefaultTabController(
        length: 3,
        animationDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 250),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '书架',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('library-bookmarks-button'),
                    onPressed: _openBookmarks,
                    icon: const Icon(Icons.bookmark_outline, size: 20),
                    label: const Text('书签'),
                  ),
                  if (widget.onReadingHistoryRequested != null)
                    IconButton(
                      key: const ValueKey('library-history-button'),
                      tooltip: '账号阅读历史',
                      onPressed: widget.onReadingHistoryRequested,
                      icon: const Icon(Icons.history),
                    ),
                ],
              ),
            ),
            TabBar(
              onTap: (index) {
                FocusManager.instance.primaryFocus?.unfocus();
              },
              tabs: const [
                Tab(key: ValueKey('library-tab-continue'), text: '续读'),
                Tab(key: ValueKey('library-tab-downloads'), text: '离线'),
                Tab(key: ValueKey('library-tab-favorites'), text: '收藏'),
              ],
            ),
            Expanded(
              child: NotificationListener<ScrollStartNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      notification.metrics.axis == Axis.horizontal) {
                    FocusManager.instance.primaryFocus?.unfocus();
                  }
                  return false;
                },
                child: TabBarView(
                  key: const ValueKey('library-tab-pages'),
                  children: [
                    _localList(
                      tab: 0,
                      count: reads.length,
                      empty: widget.continuedReads.isEmpty
                          ? '还没有阅读记录'
                          : '没有找到这本书，试试其他书名',
                      builder: (_, index) {
                        final item = reads[index];
                        return _ContinuedReadRow(
                          item: item,
                          recent:
                              _sort[0] == _LibrarySort.recent &&
                              identical(
                                item,
                                widget.continuedReads.firstOrNull,
                              ),
                          onResume: () => widget.onOpenPosition != null
                              ? widget.onOpenPosition!(
                                  item.novel,
                                  item.position,
                                )
                              : widget.onOpenNovel(item.novel),
                          onOpenDetails: () => widget.onOpenNovel(item.novel),
                        );
                      },
                    ),
                    _localList(
                      tab: 1,
                      count: downloads.length,
                      empty: widget.protectedDownloads.isEmpty
                          ? '还没有离线小说'
                          : '没有符合条件的下载，试试其他书名或状态',
                      builder: (_, index) {
                        final download = downloads[index];
                        final resume = widget.continuedReads.any(
                          (item) =>
                              item.novel.id == download.novel.id &&
                              download.chapters.any(
                                (chapter) =>
                                    chapter.chapterId ==
                                        item.position.chapterId &&
                                    chapter.taskState ==
                                        DownloadTaskState.stored,
                              ),
                        );
                        return _DownloadRow(
                          download: download,
                          actionLabel:
                              download.completedChapterCount > 0 &&
                                  widget.onOpenDownload != null
                              ? resume
                                    ? '继续阅读'
                                    : '阅读已下载章节'
                              : widget.onDownloadsManageRequested != null &&
                                    download.completedChapterCount == 0
                              ? '管理下载'
                              : '小说详情',
                          onOpen: () {
                            if (download.completedChapterCount > 0 &&
                                widget.onOpenDownload != null) {
                              widget.onOpenDownload!(download);
                            } else if (download.completedChapterCount == 0 &&
                                widget.onDownloadsManageRequested != null) {
                              widget.onDownloadsManageRequested!();
                            } else {
                              widget.onOpenNovel(download.novel);
                            }
                          },
                          onOpenDetails: () =>
                              widget.onOpenNovel(download.novel),
                        );
                      },
                    ),
                    _favorites(),
                  ].map((child) => _LibraryTabPage(child: child)).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _localList({
    required int tab,
    required int count,
    required String empty,
    required IndexedWidgetBuilder builder,
  }) {
    final name = tab == 0 ? 'continue' : 'downloads';
    return CustomScrollView(
      key: PageStorageKey('library-$name-scroll'),
      controller: _scroll[tab],
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: ValueKey('library-$name-search'),
                  controller: _search[tab],
                  onChanged: (_) => _changeResults(tab, () {}),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: tab == 0 ? '搜索读过的书' : '搜索离线书籍',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search[tab].text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () =>
                                _changeResults(tab, _search[tab].clear),
                            icon: const Icon(Icons.close),
                          ),
                    filled: true,
                    fillColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerLow,
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (tab == 1) ...[
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final filter in _DownloadFilter.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              key: ValueKey('library-filter-${filter.name}'),
                              label: Text(filter.label),
                              selected: _filter == filter,
                              onSelected: (_) =>
                                  _changeResults(1, () => _filter = filter),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      tab == 0 ? '$count 本' : '$count 项下载',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    PopupMenuButton<_LibrarySort>(
                      key: ValueKey('library-$name-sort'),
                      tooltip: '排序',
                      onOpened: () =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                      initialValue: _sort[tab],
                      onSelected: (sort) =>
                          _changeResults(tab, () => _sort[tab] = sort),
                      itemBuilder: (_) => [
                        CheckedPopupMenuItem(
                          key: const ValueKey('library-sort-recent'),
                          value: _LibrarySort.recent,
                          checked: _sort[tab] == _LibrarySort.recent,
                          child: Text(tab == 0 ? '最近阅读' : '最近活动'),
                        ),
                        CheckedPopupMenuItem(
                          key: const ValueKey('library-sort-title'),
                          value: _LibrarySort.title,
                          checked: _sort[tab] == _LibrarySort.title,
                          child: const Text('书名排序'),
                        ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _sort[tab] == _LibrarySort.title
                                  ? '书名排序'
                                  : tab == 0
                                  ? '最近阅读'
                                  : '最近活动',
                            ),
                            const Icon(Icons.arrow_drop_down, size: 20),
                          ],
                        ),
                      ),
                    ),
                    if (tab == 1 && widget.onDownloadsManageRequested != null)
                      TextButton.icon(
                        key: const ValueKey('downloads-manage-button'),
                        onPressed: widget.onDownloadsManageRequested,
                        icon: const Icon(Icons.downloading, size: 18),
                        label: const Text('管理下载'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          sliver: count == 0
              ? SliverToBoxAdapter(child: _LibraryEmpty(message: empty))
              : SliverList.separated(
                  itemCount: count,
                  itemBuilder: builder,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                ),
        ),
      ],
    );
  }

  Widget _favorites() {
    final favorites = widget.remoteFavorites;
    return ListView.builder(
      key: const PageStorageKey('favorite-folders-list'),
      controller: _scroll[2],
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      itemCount: favorites.status == RemoteFavoritesStatus.available
          ? favorites.folders.length
          : 1,
      itemBuilder: (_, index) {
        if (favorites.status == RemoteFavoritesStatus.unavailable) {
          return Column(
            children: [
              _LibraryEmpty(
                message: widget.isSignedIn == false ? '登录后查看账号收藏' : '远程收藏夹暂不可用',
              ),
              if (widget.isSignedIn == false &&
                  widget.onSignInRequested != null)
                TextButton(
                  onPressed: widget.onSignInRequested,
                  child: const Text('登录账号'),
                ),
            ],
          );
        }
        if (favorites.status == RemoteFavoritesStatus.empty) {
          return const _LibraryEmpty(message: '收藏夹为空');
        }
        final folder = favorites.folders[index];
        return ListTile(
          key: ValueKey('favorite-folder-${folder.id}'),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          leading: const Icon(Icons.folder_outlined),
          title: Text(folder.title),
          subtitle: Text(
            folder.novelCount == null ? '账号收藏夹' : '${folder.novelCount} 部小说',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: widget.onFavoriteFolderRequested == null
              ? null
              : () => widget.onFavoriteFolderRequested!(folder),
        );
      },
    );
  }
}

class _LibraryTabPage extends StatefulWidget {
  const _LibraryTabPage({required this.child});

  final Widget child;

  @override
  State<_LibraryTabPage> createState() => _LibraryTabPageState();
}

class _LibraryTabPageState extends State<_LibraryTabPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _ContinuedReadRow extends StatelessWidget {
  const _ContinuedReadRow({
    required this.item,
    required this.recent,
    required this.onResume,
    required this.onOpenDetails,
  });
  final LibraryContinuedRead item;
  final bool recent;
  final VoidCallback onResume;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final percent = (item.progress * 100).round();
    final location = item.chapterLabel ?? item.position.chapterId;
    return Material(
      color: recent ? colors.secondaryContainer : colors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: '继续阅读：${item.novel.chineseTitle}，$location，$percent%',
              excludeSemantics: true,
              onTap: onResume,
              child: InkWell(
                key: ValueKey('continued-read-${item.novel.id}'),
                onTap: onResume,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (recent) ...[
                        Text(
                          '最近阅读',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: colors.onSecondaryContainer),
                        ),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        item.novel.chineseTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$location · $percent%',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      if (recent) ...[
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: item.progress,
                          minHeight: 3,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: ValueKey('continued-read-details-${item.novel.id}'),
            tooltip: '小说详情：${item.novel.chineseTitle}',
            onPressed: onOpenDetails,
            icon: const Icon(Icons.info_outline, size: 22),
          ),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.download,
    required this.actionLabel,
    required this.onOpen,
    required this.onOpenDetails,
  });
  final LibraryProtectedDownload download;
  final String actionLabel;
  final VoidCallback onOpen;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = download.countWithState(DownloadTaskState.failed) > 0;
    final paused =
        !download.enabled ||
        download.countWithState(DownloadTaskState.paused) > 0;
    final status = download.isComplete
        ? '已完成'
        : failed
        ? '下载失败'
        : paused
        ? '已暂停'
        : '未完成';
    final icon = download.isComplete
        ? Icons.download_done
        : failed
        ? Icons.error_outline
        : paused
        ? Icons.pause_circle_outline
        : Icons.downloading;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            key: ValueKey('offline-download-${download.groupKey}'),
            borderRadius: BorderRadius.circular(12),
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    download.novel.chineseTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        icon,
                        size: 18,
                        color: failed ? colors.error : colors.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '$status · ${download.completedChapterCount}/${download.chapters.length} 章',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    libraryDownloadSummary(download),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    actionLabel,
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: colors.primary),
                  ),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          key: ValueKey('offline-download-details-${download.groupKey}'),
          tooltip: '小说详情：${download.novel.chineseTitle}',
          onPressed: onOpenDetails,
          icon: const Icon(Icons.info_outline, size: 22),
        ),
      ],
    );
  }
}

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 12),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}
