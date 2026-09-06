import 'package:flutter/material.dart';

import 'catalog_models.dart';

class CatalogNovelCard extends StatelessWidget {
  const CatalogNovelCard({
    required this.novel,
    required this.onOpen,
    required this.onTagSelected,
    this.compact = false,
    this.progress,
    this.openKey,
    this.openSemanticLabel,
    this.onOpenDetails,
    this.footer,
    super.key,
  });

  final CatalogNovel novel;
  final VoidCallback onOpen;
  final ValueChanged<String> onTagSelected;
  final bool compact;
  final double? progress;
  final Key? openKey;
  final String? openSemanticLabel;
  final VoidCallback? onOpenDetails;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final metadata = [
      ?novel.author,
      novel.publicationState.label,
      if (novel.knownChapterCount case final chapterCount?) '$chapterCount 章',
    ].join(' · ');
    return Card(
      key: ValueKey('catalog-card-${novel.id}'),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: openSemanticLabel ?? '打开小说：${novel.chineseTitle}',
            child: InkWell(
              key: openKey ?? ValueKey('open-details-${novel.id}'),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                novel.chineseTitle,
                                maxLines: compact ? 2 : null,
                                overflow: compact
                                    ? TextOverflow.ellipsis
                                    : null,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                novel.japaneseTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                locale: const Locale('ja', 'JP'),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _SourceBadge(source: novel.source),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      metadata,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final coverage in novel.translationCoverage)
                          _CoverageBadge(coverage: coverage),
                      ],
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [
                          for (final tag in novel.tags)
                            ActionChip(
                              key: ValueKey('catalog-tag-${novel.id}-$tag'),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              labelPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              label: Text(tag),
                              onPressed: () => onTagSelected(tag),
                            ),
                        ],
                      ),
                      if (novel.updatedAt case final updatedAt?) ...[
                        const SizedBox(height: 8),
                        Text(
                          '更新于 ${formatCatalogDate(updatedAt)}',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                    if (progress case final value?) ...[
                      const SizedBox(height: 14),
                      Semantics(
                        label: '阅读进度 ${(value * 100).round()}%',
                        child: LinearProgressIndicator(
                          key: ValueKey('reading-progress-${novel.id}'),
                          value: value,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
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
                  key: ValueKey('continued-details-${novel.id}'),
                  onPressed: onOpenDetails,
                  icon: const Icon(Icons.info_outline),
                  label: const Text('小说详情'),
                ),
              ),
            ),
          ?footer,
        ],
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(
          source,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.onSecondaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _CoverageBadge extends StatelessWidget {
  const _CoverageBadge({required this.coverage});

  final TranslationCoverage coverage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = coverage.isComplete
        ? colors.primaryContainer
        : colors.tertiaryContainer;
    final foreground = coverage.isComplete
        ? colors.onPrimaryContainer
        : colors.onTertiaryContainer;
    return Semantics(
      label:
          '${coverage.source} 翻译 ${coverage.countLabel}${coverage.isKnown ? ' 章' : ''}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            coverage.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

String formatCatalogDate(DateTime date) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${twoDigits(date.month)}-${twoDigits(date.day)}';
}
