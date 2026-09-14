enum FavoriteProvider {
  kakuyomu('Kakuyomu'),
  syosetu('成为小说家吧'),
  novelup('Novelup'),
  hameln('Hameln'),
  pixiv('Pixiv'),
  alphapolis('Alphapolis');

  const FavoriteProvider(this.label);
  final String label;
}

enum FavoritePublication {
  all('全部'),
  ongoing('连载中'),
  completed('已完结'),
  shortStory('短篇');

  const FavoritePublication(this.label);
  final String label;
}

enum FavoriteRating {
  all('全部'),
  general('一般向'),
  r18('R18');

  const FavoriteRating(this.label);
  final String label;
}

enum FavoriteTranslation {
  all('全部'),
  gpt('GPT'),
  sakura('Sakura');

  const FavoriteTranslation(this.label);
  final String label;
}

enum FavoriteSort {
  updated('更新时间'),
  created('收藏时间');

  const FavoriteSort(this.label);
  final String label;
}

/// One account-scoped query, shared by every page of a Favorite Folder.
class FavoriteQuery {
  const FavoriteQuery({
    this.search = '',
    this.providers = FavoriteProvider.values,
    this.publication = FavoritePublication.all,
    this.rating = FavoriteRating.all,
    this.translation = FavoriteTranslation.all,
    this.sort = FavoriteSort.updated,
  });

  final String search;
  final List<FavoriteProvider> providers;
  final FavoritePublication publication;
  final FavoriteRating rating;
  final FavoriteTranslation translation;
  final FavoriteSort sort;

  int get filterCount =>
      (providers.toSet().length == FavoriteProvider.values.length ? 0 : 1) +
      (publication == FavoritePublication.all ? 0 : 1) +
      (rating == FavoriteRating.all ? 0 : 1) +
      (translation == FavoriteTranslation.all ? 0 : 1);

  bool get isDefault => this == const FavoriteQuery();

  FavoriteQuery copyWith({
    String? search,
    List<FavoriteProvider>? providers,
    FavoritePublication? publication,
    FavoriteRating? rating,
    FavoriteTranslation? translation,
    FavoriteSort? sort,
  }) => FavoriteQuery(
    search: search ?? this.search,
    providers: List.unmodifiable(providers ?? this.providers),
    publication: publication ?? this.publication,
    rating: rating ?? this.rating,
    translation: translation ?? this.translation,
    sort: sort ?? this.sort,
  );

  @override
  bool operator ==(Object other) =>
      other is FavoriteQuery &&
      search == other.search &&
      providers.toSet().length == other.providers.toSet().length &&
      providers.every(other.providers.contains) &&
      publication == other.publication &&
      rating == other.rating &&
      translation == other.translation &&
      sort == other.sort;

  @override
  int get hashCode => Object.hash(
    search,
    Object.hashAllUnordered(providers.toSet()),
    publication,
    rating,
    translation,
    sort,
  );
}
