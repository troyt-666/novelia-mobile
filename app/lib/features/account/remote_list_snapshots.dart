import 'dart:convert';

import '../../core/account/favorite_query.dart';
import '../../core/database/sqlite_offline_repository.dart';
import '../discover/catalog_models.dart';
import '../shell/shell_view_models.dart';
import 'remote_novel_list_screen.dart';

/// Browsed cloud lists are retained on this device, independently of login.
/// Store full outlines so ordinary reading-cache eviction cannot erase a list.
class RemoteListSnapshots {
  const RemoteListSnapshots(this.repository);
  final SqliteOfflineRepository repository;

  static String favoriteKey(String folder, int page, FavoriteQuery query) =>
      jsonEncode([
        'favorite',
        folder,
        page,
        query.search,
        (query.providers.map((p) => p.name).toSet().toList()..sort()),
        query.publication.name,
        query.rating.name,
        query.translation.name,
        query.sort.name,
      ]);
  static String historyKey(int page) => 'history/$page';

  RemoteFavoritesViewModel get folders {
    try {
      final data = repository.remoteListSnapshot('favorite-folders');
      if (data == null) return const RemoteFavoritesViewModel.unavailable();
      final folders = (data['folders'] as List)
          .map(
            (row) => LibraryFavoriteFolder(
              id: row['id'] as String,
              title: row['title'] as String,
            ),
          )
          .toList();
      return folders.isEmpty
          ? const RemoteFavoritesViewModel.empty()
          : RemoteFavoritesViewModel.available(folders);
    } on Object {
      return const RemoteFavoritesViewModel.unavailable();
    }
  }

  void saveFolders(List<LibraryFavoriteFolder> folders) =>
      repository.saveRemoteListSnapshot('favorite-folders', {
        'folders': [
          for (final folder in folders)
            {'id': folder.id, 'title': folder.title},
        ],
      });

  void savePage(String key, RemoteNovelPageView page) =>
      repository.saveRemoteListSnapshot(key, {
        'page': page.pageNumber,
        'total': page.totalPages,
        'novels': [
          for (final n in page.novels)
            {
              'id': n.id,
              'title': n.chineseTitle,
              'originalTitle': n.japaneseTitle,
              'author': n.author,
              'source': n.source,
              'state': n.publicationState.name,
              'words': n.wordCount,
              'updated': n.updatedAt?.toIso8601String(),
              'tags': n.tags,
              'synopsis': n.synopsis,
              'points': n.points,
              'views': n.views,
              'chapters': n.knownChapterCount,
              'url': n.originalUrl?.toString(),
              'favorite': n.isFavorite,
              'folder': n.favoriteFolderId,
              'translations': [
                for (final c in n.translationCoverage)
                  {
                    'source': c.source,
                    'translated': c.translatedChapters,
                    'total': c.totalChapters,
                  },
              ],
            },
        ],
      });

  RemoteNovelPageView? page(String key) {
    try {
      final data = repository.remoteListSnapshot(key);
      if (data == null) return null;
      return RemoteNovelPageView(
        pageNumber: data['page'] as int,
        totalPages: data['total'] as int,
        novels: [
          for (final n in data['novels'] as List)
            CatalogNovel(
              id: n['id'] as String,
              chineseTitle: n['title'] as String,
              japaneseTitle: n['originalTitle'] as String,
              author: n['author'] as String?,
              source: n['source'] as String,
              publicationState: NovelPublicationState.values.byName(
                n['state'] as String,
              ),
              wordCount: n['words'] as int?,
              updatedAt: DateTime.tryParse(n['updated'] as String? ?? ''),
              tags: (n['tags'] as List).cast<String>(),
              synopsis: n['synopsis'] as String?,
              points: n['points'] as int?,
              views: n['views'] as int?,
              declaredChapterCount: n['chapters'] as int?,
              originalUrl: n['url'] == null
                  ? null
                  : Uri.parse(n['url'] as String),
              isFavorite: n['favorite'] as bool,
              favoriteFolderId: n['folder'] as String?,
              translationCoverage: [
                for (final c in n['translations'] as List)
                  TranslationCoverage(
                    source: c['source'] as String,
                    translatedChapters: c['translated'] as int?,
                    totalChapters: c['total'] as int?,
                  ),
              ],
            ),
        ],
      );
    } on Object {
      return null;
    }
  }
}
