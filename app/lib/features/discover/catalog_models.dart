import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/model/reader_models.dart';

enum NovelPublicationState {
  ongoing('连载中'),
  completed('已完结'),
  shortStory('短篇'),
  unknown('状态未知');

  const NovelPublicationState(this.label);

  final String label;
}

enum CatalogSort {
  recentlyUpdated('最近更新'),
  mostClicked('最多点击'),
  relevance('相关程度');

  const CatalogSort(this.label);

  final String label;
}

enum CatalogAvailability { available, authenticationRequired, offline }

/// Package-neutral criteria for the Web Novel catalog.
///
/// Values intentionally use the labels already presented by the feature UI;
/// the gateway composition root owns conversion to service-specific codes.
@immutable
class CatalogCriteria {
  const CatalogCriteria({
    this.search = '',
    this.source,
    this.publicationState,
    this.translationSource,
    this.exactTag,
    this.sort = CatalogSort.recentlyUpdated,
  });

  final String search;
  final String? source;
  final NovelPublicationState? publicationState;
  final String? translationSource;
  final String? exactTag;
  final CatalogSort sort;

  @override
  bool operator ==(Object other) =>
      other is CatalogCriteria &&
      other.search == search &&
      other.source == source &&
      other.publicationState == publicationState &&
      other.translationSource == translationSource &&
      other.exactTag == exactTag &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(
    search,
    source,
    publicationState,
    translationSource,
    exactTag,
    sort,
  );
}

typedef CatalogCriteriaRequested =
    FutureOr<void> Function(CatalogCriteria criteria);

/// Hydrates a catalog outline with detail metadata and a chapter catalog.
///
/// Chapter entries may contain no blocks. Chapter bodies belong to
/// [ReaderLaunchLoader], so opening details never requires a full-novel fetch.
typedef NovelDetailsLoader =
    Future<CatalogNovel> Function(CatalogNovel outline);

/// Loads the bounded chapter window needed to enter the reader.
///
/// Implementations should return the selected chapter and only the adjacent
/// chapters needed for the initial reading window, not every chapter body.
typedef ReaderLaunchLoader =
    Future<ReaderLaunchData> Function(
      CatalogNovel novel,
      NovelChapter? selectedChapter,
      ReadingPosition? requestedPosition,
    );

/// Loads exactly one service-defined page of comments.
typedef NovelCommentPageLoader =
    Future<NovelCommentPage> Function(CatalogNovel novel, int pageNumber);

@immutable
class ReaderLaunchData {
  const ReaderLaunchData({
    required this.novel,
    this.initialPosition,
    this.dataSource,
  });

  final ReaderNovel novel;
  final ReadingPosition? initialPosition;

  /// Optional dynamic source for a bounded body window and the full TOC.
  ///
  /// Fixture launches may omit it and retain the original fully synchronous
  /// reader behavior.
  final ReaderChapterDataSource? dataSource;
}

@immutable
class NovelCommentPage {
  NovelCommentPage({
    required this.pageNumber,
    required this.totalPages,
    required this.totalComments,
    required this.comments,
  }) {
    if (pageNumber < 1) {
      throw ArgumentError.value(pageNumber, 'pageNumber', 'Must be positive.');
    }
    if (totalPages < 0) {
      throw ArgumentError.value(
        totalPages,
        'totalPages',
        'Cannot be negative.',
      );
    }
    if (totalPages > 0 && pageNumber > totalPages) {
      throw ArgumentError.value(
        pageNumber,
        'pageNumber',
        'Cannot exceed totalPages.',
      );
    }
    if (totalComments != null && totalComments! < 0) {
      throw ArgumentError.value(
        totalComments,
        'totalComments',
        'Cannot be negative.',
      );
    }
  }

  final int pageNumber;
  final int totalPages;

  /// Exact service total when exposed by the endpoint.
  ///
  /// This stays null when only page-count metadata is available.
  final int? totalComments;
  final List<NovelComment> comments;
}

@immutable
class TranslationCoverage {
  const TranslationCoverage({
    required this.source,
    required this.translatedChapters,
    required this.totalChapters,
  });

  final String source;
  final int translatedChapters;
  final int totalChapters;

  bool get hasTranslation => translatedChapters > 0;
  bool get isComplete => translatedChapters == totalChapters;
  String get label => '$source $translatedChapters/$totalChapters';
}

@immutable
class NovelCommentReply {
  const NovelCommentReply({
    required this.id,
    required this.author,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String author;
  final String body;
  final DateTime createdAt;
}

@immutable
class NovelComment {
  const NovelComment({
    required this.id,
    required this.author,
    required this.body,
    required this.createdAt,
    this.replies = const [],
  });

  final String id;
  final String author;
  final String body;
  final DateTime createdAt;
  final List<NovelCommentReply> replies;
}

@immutable
class CatalogChapterSection {
  const CatalogChapterSection({required this.title, required this.chapterIds});

  final String title;
  final List<String> chapterIds;
}

@immutable
class CatalogNovel {
  const CatalogNovel({
    required this.id,
    required this.chineseTitle,
    required this.japaneseTitle,
    this.author,
    required this.source,
    required this.publicationState,
    this.wordCount,
    this.updatedAt,
    required this.tags,
    this.synopsis,
    this.points,
    this.views,
    required this.translationCoverage,
    this.readerNovel,
    this.declaredChapterCount,
    this.chapterSections = const [],
    this.comments = const [],
    this.originalUrl,
  }) : assert(
         declaredChapterCount == null || declaredChapterCount >= 0,
         'declaredChapterCount cannot be negative.',
       );

  final String id;
  final String chineseTitle;
  final String japaneseTitle;
  final String? author;
  final String source;
  final NovelPublicationState publicationState;
  final int? wordCount;
  final DateTime? updatedAt;
  final List<String> tags;
  final String? synopsis;
  final int? points;
  final int? views;
  final List<TranslationCoverage> translationCoverage;

  /// A hydrated chapter catalog, optionally containing fixture chapter bodies.
  ///
  /// Live catalog outlines should leave this null. Detail hydration may fill
  /// chapter metadata with empty block lists; [ReaderLaunchLoader] owns body
  /// loading and returns a bounded readable window.
  final ReaderNovel? readerNovel;
  final int? declaredChapterCount;
  final List<CatalogChapterSection> chapterSections;
  final List<NovelComment> comments;
  final Uri? originalUrl;

  /// Known chapter total, or null when neither service metadata nor a hydrated
  /// catalog establishes it.
  int? get knownChapterCount =>
      declaredChapterCount ?? readerNovel?.chapters.length;

  /// Compatibility value for domain calculations that require an integer.
  /// Presentation code should use [knownChapterCount] so unknown is not shown
  /// as a fabricated zero.
  int get chapterCount => knownChapterCount ?? 0;

  bool get hasChapterCatalog => readerNovel != null;

  TranslationCoverage? coverageFor(String sourceName) {
    for (final coverage in translationCoverage) {
      if (coverage.source == sourceName) return coverage;
    }
    return null;
  }
}
