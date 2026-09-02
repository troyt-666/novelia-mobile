import '../model/reader_models.dart';

enum ThemePreference { system, light, dark }

class LocalReadingProgress {
  const LocalReadingProgress({
    required this.novelId,
    required this.position,
    required this.updatedAt,
  });

  final String novelId;
  final ReadingPosition position;
  final DateTime updatedAt;
}

class LocalBookmark {
  const LocalBookmark({
    required this.id,
    required this.novelId,
    required this.position,
    required this.createdAt,
  });

  final String id;
  final String novelId;
  final ReadingPosition position;
  final DateTime createdAt;
}

/// The destination restored after process termination.
///
/// A top-level destination has no [novelId] or [position]. A reader route has
/// both so it can be restored without first painting the chapter top.
class LastRouteState {
  LastRouteState({
    required this.routeName,
    required this.updatedAt,
    this.novelId,
    this.position,
  }) {
    if (routeName.isEmpty) throw ArgumentError.value(routeName, 'routeName');
    if ((novelId == null) != (position == null)) {
      throw ArgumentError(
        'A reader route must contain both novel ID and Reading Position.',
      );
    }
  }

  final String routeName;
  final String? novelId;
  final ReadingPosition? position;
  final DateTime updatedAt;
}

class LocalAppSettings {
  LocalAppSettings({
    required this.readerSettings,
    required this.themePreference,
    required this.cacheLimitBytes,
    required this.updatedAt,
  }) {
    if (cacheLimitBytes < 0) {
      throw ArgumentError.value(cacheLimitBytes, 'cacheLimitBytes');
    }
  }

  final ReaderSettings readerSettings;
  final ThemePreference themePreference;
  final int cacheLimitBytes;
  final DateTime updatedAt;
}

abstract interface class LocalStateRepository {
  void saveReadingProgress(LocalReadingProgress progress);

  LocalReadingProgress? readingProgressFor(String novelId);

  List<LocalReadingProgress> listReadingProgress();

  void saveBookmark(LocalBookmark bookmark);

  List<LocalBookmark> listBookmarks({String? novelId});

  void removeBookmark(String id);

  void saveLastRoute(LastRouteState state);

  LastRouteState? lastRoute();

  /// Replaces the local, device-only catalog query history in display order.
  ///
  /// Implementations keep at most eight trimmed, non-empty, unique queries.
  void saveRecentSearches(List<String> queries);

  List<String> recentSearches();

  void saveAppSettings(LocalAppSettings settings);

  LocalAppSettings? appSettings();
}
