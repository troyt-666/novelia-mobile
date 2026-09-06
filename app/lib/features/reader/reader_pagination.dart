import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/model/reader_models.dart';

/// Composes one loaded reading window; null items represent its end boundaries.
/// Layout depends only on content, settings, text scale, and available space.
class ReaderPagination {
  ReaderPagination.compose({
    required this.items,
    required this.settings,
    required this.textScaler,
    required double viewportWidth,
    required double availableHeight,
  }) {
    pages = _composeHorizontalPages(viewportWidth, availableHeight);
  }

  final List<ReaderStreamItem?> items;
  final ReaderSettings settings;
  final TextScaler textScaler;
  late final List<ReaderHorizontalPage> pages;
  final Map<String, List<_ReaderHorizontalLocation>>
  _horizontalLocationsByStableId = {};

  int? pageForStableId(String stableId, int intraBlockOffset) {
    final locations = _horizontalLocationsByStableId[stableId];
    if (locations == null || locations.isEmpty) return null;
    var selected = locations.first;
    for (final location in locations.skip(1)) {
      if (location.intraBlockOffset > intraBlockOffset) break;
      selected = location;
    }
    return selected.pageIndex;
  }

  double _measureTextHeight(
    String text,
    TextStyle style,
    double width, {
    Locale? locale,
  }) {
    if (text.isEmpty) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: math.max(1, width));
    final height = painter.height;
    painter.dispose();
    return height;
  }

  double _estimateReaderItemHeight(int index, double viewportWidth) {
    final item = items[index];
    if (item == null) return 76;
    if (item is ChapterBoundaryItem) {
      final titleWidth = math.max(
        1.0,
        math.min(viewportWidth, settings.readingWidth) -
            settings.pageMargin * 2,
      );
      final family = settings.fontFamily == ReaderFontFamily.systemSerif
          ? 'serif'
          : null;
      return 128 +
          _measureTextHeight(
            item.chapter.chineseTitle,
            TextStyle(
              fontSize: 27,
              height: 1.3,
              fontWeight: FontWeight.w700,
              fontFamily: family,
            ),
            titleWidth,
            locale: const Locale('zh', 'CN'),
          ) +
          _measureTextHeight(
            item.chapter.japaneseTitle,
            const TextStyle(fontSize: 15, height: 1.4),
            titleWidth,
            locale: const Locale('ja', 'JP'),
          ) +
          (item.chapter.translationState(settings.translationSource) ==
                  TranslationState.complete
              ? 0
              : 82);
    }
    if (item is! AlignedBlockItem) return 0;
    final block = item.block;
    final availableWidth = math.min(viewportWidth, settings.readingWidth);
    if (block.kind == AlignedBlockKind.illustration) {
      return math.max(180.0, (availableWidth - 32) / 0.75 + 32);
    }
    final translationState = item.chapter.translationState(
      settings.translationSource,
    );
    final translation = translationState == TranslationState.complete
        ? block.translationFor(settings.translationSource)
        : null;
    final showJapanese =
        translation == null ||
        settings.readingMode == ReadingMode.chineseJapanese;
    final dialogue = block.kind == AlignedBlockKind.dialogue;
    final horizontalPadding = settings.pageMargin * 2 + (dialogue ? 16 : 0);
    final textWidth = math.max(1.0, availableWidth - horizontalPadding);
    final parallel =
        translation != null &&
        showJapanese &&
        usesReaderParallelColumns(settings, viewportWidth);
    final bodyWeight = settings.bodyBold ? FontWeight.w600 : FontWeight.w400;
    final family = settings.fontFamily == ReaderFontFamily.systemSerif
        ? 'serif'
        : null;
    final columnWidth = parallel
        ? math.max(1.0, (textWidth - 28) / 2)
        : textWidth;
    final chineseHeight = translation == null
        ? 0.0
        : _measureTextHeight(
            translation,
            TextStyle(
              fontSize: settings.chineseFontSize,
              height: settings.lineHeight,
              fontWeight: bodyWeight,
              fontFamily: family,
              letterSpacing: 0.15,
            ),
            columnWidth,
            locale: const Locale('zh', 'CN'),
          );
    final japaneseHeight = !showJapanese
        ? 0.0
        : _measureTextHeight(
            block.japanese,
            TextStyle(
              fontSize: translation == null
                  ? settings.chineseFontSize * 0.92
                  : settings.japaneseFontSize,
              height: settings.lineHeight,
              fontWeight: bodyWeight,
              fontFamily: family,
            ),
            columnWidth,
            locale: const Locale('ja', 'JP'),
          );
    final textHeight = parallel
        ? math.max(chineseHeight, japaneseHeight)
        : chineseHeight +
              japaneseHeight +
              (chineseHeight > 0 && japaneseHeight > 0
                  ? settings.chineseFontSize * 0.42
                  : 0);
    return 9 + textHeight + settings.paragraphSpacing + 4;
  }

  List<ReaderHorizontalPage> _composeHorizontalPages(
    double viewportWidth,
    double availableHeight,
  ) {
    final pages = <ReaderHorizontalPage>[];
    var entries = <ReaderHorizontalEntry>[];
    var estimatedHeight = 0.0;

    void finishPage() {
      if (entries.isEmpty) return;
      final pageIndex = pages.length;
      AlignedBlockItem? anchor;
      var anchorIntraBlockOffset = 0;
      for (final entry in entries) {
        final stableId = items[entry.readerItemIndex]?.stableId;
        if (stableId == null) continue;
        final location = _ReaderHorizontalLocation(
          pageIndex: pageIndex,
          intraBlockOffset: entry.fragment?.intraBlockOffset ?? 0,
        );
        _horizontalLocationsByStableId
            .putIfAbsent(stableId, () => [])
            .add(location);
        if (anchor != null) continue;
        final item = items[entry.readerItemIndex];
        if (item is AlignedBlockItem) {
          anchor = item;
          anchorIntraBlockOffset = location.intraBlockOffset;
        } else if (item is ChapterBoundaryItem) {
          final firstBlock = item.chapter.blocks.firstOrNull;
          if (firstBlock != null) {
            anchor = AlignedBlockItem(chapter: item.chapter, block: firstBlock);
          }
        }
      }
      pages.add(
        ReaderHorizontalPage(
          entries: entries,
          anchor: anchor,
          anchorIntraBlockOffset: anchorIntraBlockOffset,
        ),
      );
      entries = <ReaderHorizontalEntry>[];
      estimatedHeight = 0;
    }

    void addEntry(ReaderHorizontalEntry entry, double height) {
      if (entries.isNotEmpty && estimatedHeight + height > availableHeight) {
        finishPage();
      }
      entries.add(entry);
      estimatedHeight += height;
    }

    for (var index = 0; index < items.length; index++) {
      final itemHeight = _estimateReaderItemHeight(index, viewportWidth);
      final item = items[index];
      if (item is AlignedBlockItem &&
          item.block.kind != AlignedBlockKind.illustration &&
          itemHeight > availableHeight) {
        finishPage();
        for (final entry in _fragmentHorizontalBlock(
          index,
          item,
          viewportWidth,
          availableHeight,
        )) {
          addEntry(entry, entry.fragment!.estimatedHeight);
        }
        continue;
      }
      if (itemHeight > availableHeight) {
        finishPage();
        addEntry(
          ReaderHorizontalEntry(readerItemIndex: index, scaleToFit: true),
          availableHeight,
        );
        finishPage();
        continue;
      }
      addEntry(ReaderHorizontalEntry(readerItemIndex: index), itemHeight);
    }
    finishPage();
    if (pages.isEmpty) {
      pages.add(
        const ReaderHorizontalPage(
          entries: [],
          anchor: null,
          anchorIntraBlockOffset: 0,
        ),
      );
    }
    return pages;
  }

  List<ReaderHorizontalEntry> _fragmentHorizontalBlock(
    int readerItemIndex,
    AlignedBlockItem item,
    double viewportWidth,
    double availableHeight,
  ) {
    final translationState = item.chapter.translationState(
      settings.translationSource,
    );
    final translation = translationState == TranslationState.complete
        ? item.block.translationFor(settings.translationSource)
        : null;
    final showJapanese =
        translation == null ||
        settings.readingMode == ReadingMode.chineseJapanese;
    final dialogue = item.block.kind == AlignedBlockKind.dialogue;
    final availableWidth = math.min(viewportWidth, settings.readingWidth);
    final textWidth = math.max(
      1.0,
      availableWidth - settings.pageMargin * 2 - (dialogue ? 16.0 : 0.0),
    );
    final parallel =
        translation != null &&
        showJapanese &&
        usesReaderParallelColumns(settings, viewportWidth);
    final columnWidth = parallel
        ? math.max(1.0, (textWidth - 28) / 2)
        : textWidth;
    final bodyWeight = settings.bodyBold ? FontWeight.w600 : FontWeight.w400;
    final family = settings.fontFamily == ReaderFontFamily.systemSerif
        ? 'serif'
        : null;
    final chineseStyle = TextStyle(
      fontSize: settings.chineseFontSize,
      height: settings.lineHeight,
      fontWeight: bodyWeight,
      fontFamily: family,
      letterSpacing: 0.15,
    );
    final japaneseStyle = TextStyle(
      fontSize: translation == null
          ? settings.chineseFontSize * 0.92
          : settings.japaneseFontSize,
      height: settings.lineHeight,
      fontWeight: bodyWeight,
      fontFamily: family,
    );
    final maxTextHeight = math.max(
      1.0,
      availableHeight - 9 - settings.paragraphSpacing,
    );
    final totalLength =
        (translation?.length ?? 0) +
        (showJapanese ? item.block.japanese.length : 0);
    final fragments = <ReaderHorizontalEntry>[];
    var consumed = 0;

    void addFragment({String? chinese, String? japanese}) {
      final chineseHeight = chinese == null
          ? 0.0
          : _measureTextHeight(
              chinese,
              chineseStyle,
              columnWidth,
              locale: const Locale('zh', 'CN'),
            );
      final japaneseHeight = japanese == null
          ? 0.0
          : _measureTextHeight(
              japanese,
              japaneseStyle,
              columnWidth,
              locale: const Locale('ja', 'JP'),
            );
      final contentHeight = parallel
          ? math.max(chineseHeight, japaneseHeight)
          : chineseHeight + japaneseHeight;
      fragments.add(
        ReaderHorizontalEntry(
          readerItemIndex: readerItemIndex,
          fragment: ReaderTextFragment(
            index: fragments.length,
            chinese: chinese,
            japanese: japanese,
            intraBlockOffset: totalLength == 0
                ? 0
                : (consumed / totalLength * 1000).round().clamp(0, 1000),
            estimatedHeight: 9 + contentHeight + settings.paragraphSpacing,
          ),
        ),
      );
      consumed += (chinese?.length ?? 0) + (japanese?.length ?? 0);
    }

    if (parallel) {
      var chineseRemaining = translation;
      var japaneseRemaining = showJapanese ? item.block.japanese : '';
      while (chineseRemaining.isNotEmpty || japaneseRemaining.isNotEmpty) {
        final chinese = _takeTextPrefixThatFits(
          chineseRemaining,
          chineseStyle,
          columnWidth,
          maxTextHeight,
          locale: const Locale('zh', 'CN'),
        );
        final japanese = _takeTextPrefixThatFits(
          japaneseRemaining,
          japaneseStyle,
          columnWidth,
          maxTextHeight,
          locale: const Locale('ja', 'JP'),
        );
        addFragment(
          chinese: chinese.isEmpty ? null : chinese,
          japanese: japanese.isEmpty ? null : japanese,
        );
        chineseRemaining = chineseRemaining.substring(chinese.length);
        japaneseRemaining = japaneseRemaining.substring(japanese.length);
      }
    } else {
      void splitLanguage(
        String text,
        TextStyle style,
        Locale locale,
        bool chinese,
      ) {
        var remaining = text;
        while (remaining.isNotEmpty) {
          final part = _takeTextPrefixThatFits(
            remaining,
            style,
            columnWidth,
            maxTextHeight,
            locale: locale,
          );
          addFragment(
            chinese: chinese ? part : null,
            japanese: chinese ? null : part,
          );
          remaining = remaining.substring(part.length);
        }
      }

      if (translation != null) {
        splitLanguage(
          translation,
          chineseStyle,
          const Locale('zh', 'CN'),
          true,
        );
      }
      if (showJapanese) {
        splitLanguage(
          item.block.japanese,
          japaneseStyle,
          const Locale('ja', 'JP'),
          false,
        );
      }
    }
    return fragments;
  }

  String _takeTextPrefixThatFits(
    String text,
    TextStyle style,
    double width,
    double maxHeight, {
    required Locale locale,
  }) {
    if (text.isEmpty ||
        _measureTextHeight(text, style, width, locale: locale) <= maxHeight) {
      return text;
    }
    var low = 1;
    var high = text.length;
    var best = 0;
    while (low <= high) {
      final midpoint = (low + high) ~/ 2;
      var middle = midpoint;
      if (middle < text.length &&
          middle > 0 &&
          _isLowSurrogate(text.codeUnitAt(middle)) &&
          _isHighSurrogate(text.codeUnitAt(middle - 1))) {
        middle -= 1;
      }
      if (middle <= 0) {
        low = midpoint + 1;
        continue;
      }
      final candidate = text.substring(0, middle);
      final fits =
          _measureTextHeight(candidate, style, width, locale: locale) <=
          maxHeight;
      if (fits) {
        best = middle;
        low = midpoint + 1;
      } else {
        high = middle - 1;
      }
    }
    if (best > 0) return text.substring(0, best);
    final firstLength =
        text.length > 1 &&
            _isHighSurrogate(text.codeUnitAt(0)) &&
            _isLowSurrogate(text.codeUnitAt(1))
        ? 2
        : 1;
    return text.substring(0, firstLength);
  }

  bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
}

class ReaderHorizontalPage {
  const ReaderHorizontalPage({
    required this.entries,
    required this.anchor,
    required this.anchorIntraBlockOffset,
  });

  final List<ReaderHorizontalEntry> entries;
  final AlignedBlockItem? anchor;
  final int anchorIntraBlockOffset;
}

class ReaderHorizontalEntry {
  const ReaderHorizontalEntry({
    required this.readerItemIndex,
    this.fragment,
    this.scaleToFit = false,
  });

  final int readerItemIndex;
  final ReaderTextFragment? fragment;
  final bool scaleToFit;
}

class ReaderTextFragment {
  const ReaderTextFragment({
    required this.index,
    required this.chinese,
    required this.japanese,
    required this.intraBlockOffset,
    required this.estimatedHeight,
  });

  final int index;
  final String? chinese;
  final String? japanese;
  final int intraBlockOffset;
  final double estimatedHeight;
}

class _ReaderHorizontalLocation {
  const _ReaderHorizontalLocation({
    required this.pageIndex,
    required this.intraBlockOffset,
  });

  final int pageIndex;
  final int intraBlockOffset;
}

bool usesReaderParallelColumns(ReaderSettings settings, double viewportWidth) {
  return viewportWidth >= 1000 &&
      settings.columnLayout != ReaderColumnLayout.singleColumn;
}
