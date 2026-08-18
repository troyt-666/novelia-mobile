import '../../core/account/account_sync_models.dart';
import 'novelia_gateway.dart';

typedef AccountAccessTokenProvider =
    Future<String?> Function({bool forceRefresh});

abstract interface class NoveliaAccountGateway {
  Future<List<RemoteFavoriteFolder>> listFavoriteFolders();

  Future<NoveliaPage<NoveliaNovelOutline>> listFavoriteWebNovels({
    required String folderId,
    int page = 0,
    int pageSize = 30,
  });

  Future<NoveliaPage<NoveliaNovelOutline>> listReadHistory({
    int page = 0,
    int pageSize = 30,
  });

  Future<RemoteFavoriteFolder> createFavoriteFolder(String title);

  Future<void> favoriteWebNovel({
    required String folderId,
    required String providerId,
    required String novelId,
  });

  Future<void> unfavoriteWebNovel({
    required String folderId,
    required String providerId,
    required String novelId,
  });

  Future<void> updateReadHistory({
    required String providerId,
    required String novelId,
    required String chapterId,
  });
}
