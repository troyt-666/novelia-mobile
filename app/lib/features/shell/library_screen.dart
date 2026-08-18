import 'package:flutter/material.dart';

import '../../core/model/reader_models.dart';
import '../discover/catalog_models.dart';
import 'shell_view_models.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({
    required this.onOpenNovel,
    this.onOpenPosition,
    this.novels = const [],
    this.continuedReads = const [],
    this.protectedDownloads = const [],
    this.bookmarks = const [],
    this.remoteFavorites = const RemoteFavoritesViewModel.unavailable(),
    this.onFavoriteFolderRequested,
    this.onReadingHistoryRequested,
    this.onDownloadsManageRequested,
    super.key,
  });

  /// Temporarily retained so existing shell call sites remain compatible.
  /// Displayed data comes only from the explicit view-model collections.
  final List<CatalogNovel> novels;
  final ValueChanged<CatalogNovel> onOpenNovel;
  final void Function(CatalogNovel novel, ReadingPosition position)?
  onOpenPosition;
  final List<LibraryContinuedRead> continuedReads;
  final List<LibraryProtectedDownload> protectedDownloads;
  final List<LibraryBookmarkItem> bookmarks;
  final RemoteFavoritesViewModel remoteFavorites;
  final ValueChanged<LibraryFavoriteFolder>? onFavoriteFolderRequested;
  final VoidCallback? onReadingHistoryRequested;
  final VoidCallback? onDownloadsManageRequested;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListView(
        key: const PageStorageKey('library-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: [
          Text(
            '书架',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            '阅读进度、收藏与离线内容',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _LibraryHeader(
            title: '继续阅读',
            actionLabel: '阅读历史',
            onAction: onReadingHistoryRequested,
          ),
          const SizedBox(height: 10),
          if (continuedReads.isEmpty)
            const _LibraryEmpty(message: '还没有阅读记录')
          else
            ..._withSpacing(
              continuedReads.map(
                (item) => _ContinuedReadCard(
                  item: item,
                  onResume: () => onOpenPosition != null
                      ? onOpenPosition!(item.novel, item.position)
                      : onOpenNovel(item.novel),
                  onOpenDetails: onOpenPosition == null
                      ? null
                      : () => onOpenNovel(item.novel),
                ),
              ),
            ),
          const SizedBox(height: 28),
          const _LibraryHeader(title: '收藏夹'),
          const SizedBox(height: 10),
          _RemoteFavorites(
            key: const ValueKey('favorite-folders-grid'),
            favorites: remoteFavorites,
            onOpenFolder: onFavoriteFolderRequested,
          ),
          const SizedBox(height: 28),
          _LibraryHeader(
            title: '离线下载',
            actionLabel: '管理',
            actionKey: const ValueKey('downloads-manage-button'),
            onAction: onDownloadsManageRequested,
          ),
          const SizedBox(height: 10),
          if (protectedDownloads.isEmpty)
            const _LibraryEmpty(message: '还没有离线小说')
          else
            ..._withSpacing(
              protectedDownloads.map(
                (download) => _DownloadCard(
                  download: download,
                  onOpen: () => onOpenNovel(download.novel),
                ),
              ),
            ),
          const SizedBox(height: 28),
          const _LibraryHeader(title: '书签'),
          const SizedBox(height: 10),
          if (bookmarks.isEmpty)
            const _LibraryEmpty(message: '还没有书签')
          else
            ..._withSpacing(
              bookmarks.map(
                (bookmark) => _BookmarkCard(
                  bookmark: bookmark,
                  onOpen: () => onOpenPosition != null
                      ? onOpenPosition!(bookmark.novel, bookmark.position)
                      : onOpenNovel(bookmark.novel),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static List<Widget> _withSpacing(Iterable<Widget> widgets) {
    final result = <Widget>[];
    for (final widget in widgets) {
      if (result.isNotEmpty) result.add(const SizedBox(height: 10));
      result.add(widget);
    }
    return result;
  }
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({
    required this.title,
    this.actionLabel,
    this.actionKey,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (actionLabel != null && onAction != null)
          TextButton(
            key: actionKey,
            onPressed: onAction,
            child: Text(actionLabel!),
          ),
      ],
    );
  }
}

class _ContinuedReadCard extends StatelessWidget {
  const _ContinuedReadCard({
    required this.item,
    required this.onResume,
    required this.onOpenDetails,
  });

  final LibraryContinuedRead item;
  final VoidCallback onResume;
  final VoidCallback? onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final percent = (item.progress * 100).round();
    final positionLabel =
        item.chapterLabel ??
        '${item.position.chapterId} · ${item.position.blockId}';
    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Semantics(
            button: true,
            label: '继续阅读：${item.novel.chineseTitle}，$positionLabel，$percent%',
            child: InkWell(
              key: ValueKey('continued-read-${item.novel.id}'),
              onTap: onResume,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.novel.chineseTitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text('$positionLabel · $percent%'),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: item.progress),
                  ],
                ),
              ),
            ),
          ),
          if (onOpenDetails != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: TextButton.icon(
                  key: ValueKey('continued-read-details-${item.novel.id}'),
                  onPressed: onOpenDetails,
                  icon: const Icon(Icons.info_outline),
                  label: const Text('小说详情'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RemoteFavorites extends StatelessWidget {
  const _RemoteFavorites({
    required this.favorites,
    required this.onOpenFolder,
    super.key,
  });

  final RemoteFavoritesViewModel favorites;
  final ValueChanged<LibraryFavoriteFolder>? onOpenFolder;

  @override
  Widget build(BuildContext context) {
    return switch (favorites.status) {
      RemoteFavoritesStatus.unavailable => const _LibraryEmpty(
        message: '远程收藏夹暂不可用',
      ),
      RemoteFavoritesStatus.empty => const _LibraryEmpty(message: '收藏夹为空'),
      RemoteFavoritesStatus.available => GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.65,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final folder in favorites.folders)
            _FolderCard(
              key: ValueKey('favorite-folder-${folder.id}'),
              title: folder.title,
              count: folder.novelCount,
              onOpen: onOpenFolder == null ? null : () => onOpenFolder!(folder),
            ),
        ],
      ),
    };
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.title,
    required this.count,
    required this.onOpen,
    super.key,
  });

  final String title;
  final int? count;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.secondaryContainer,
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: onOpen != null,
        label: '打开收藏夹：$title',
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(
                  Icons.auto_stories_outlined,
                  color: colors.onSecondaryContainer,
                ),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.onSecondaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  count == null ? '远程收藏夹' : '$count 部小说',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard({required this.download, required this.onOpen});

  final LibraryProtectedDownload download;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: ValueKey('offline-download-${download.novel.id}'),
        leading: const CircleAvatar(child: Icon(Icons.download_done)),
        title: Text(download.novel.chineseTitle),
        subtitle: Text(libraryDownloadSummary(download)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onOpen,
      ),
    );
  }
}

class _BookmarkCard extends StatelessWidget {
  const _BookmarkCard({required this.bookmark, required this.onOpen});

  final LibraryBookmarkItem bookmark;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final location =
        bookmark.chapterLabel ??
        '${bookmark.position.chapterId} · ${bookmark.position.blockId}';
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: ValueKey('bookmark-${bookmark.id}'),
        leading: const Icon(Icons.bookmark),
        title: Text(bookmark.novel.chineseTitle),
        subtitle: Text(location),
        trailing: const Icon(Icons.chevron_right),
        onTap: onOpen,
      ),
    );
  }
}

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message, textAlign: TextAlign.center),
    );
  }
}
