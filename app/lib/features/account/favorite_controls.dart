import 'package:flutter/material.dart';

import '../../core/account/favorite_query.dart';

class FavoriteToolbar extends StatelessWidget {
  const FavoriteToolbar({
    required this.query,
    required this.searchController,
    required this.onChanged,
    super.key,
  });

  final FavoriteQuery query;
  final TextEditingController searchController;
  final ValueChanged<FavoriteQuery> onChanged;

  void _submit() =>
      onChanged(query.copyWith(search: searchController.text.trim()));

  Future<void> _showFilters(BuildContext context) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await showModalBottomSheet<FavoriteQuery>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => FractionallySizedBox(
        heightFactor: .85,
        child: _FavoriteFilterSheet(
          initialQuery: query.copyWith(search: searchController.text.trim()),
        ),
      ),
    );
    if (context.mounted && result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final summary = [
      if (query.providers.length != FavoriteProvider.values.length)
        query.providers.isEmpty
            ? '未选择来源'
            : query.providers.map((p) => p.label).join('、'),
      if (query.publication != FavoritePublication.all) query.publication.label,
      if (query.rating != FavoriteRating.all) query.rating.label,
      if (query.translation != FavoriteTranslation.all) query.translation.label,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: searchController,
            builder: (context, value, _) => TextField(
              key: const ValueKey('favorite-search'),
              controller: searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: '中/日标题或作者',
                prefixIcon: IconButton(
                  key: const ValueKey('favorite-search-submit'),
                  tooltip: '搜索收藏夹',
                  onPressed: _submit,
                  icon: const Icon(Icons.search),
                ),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey('favorite-search-clear'),
                        tooltip: '清除搜索',
                        onPressed: () {
                          searchController.clear();
                          _submit();
                        },
                        icon: const Icon(Icons.close),
                      ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                key: const ValueKey('favorite-filters'),
                onPressed: () => _showFilters(context),
                icon: const Icon(Icons.tune),
                label: Text(
                  query.filterCount == 0 ? '筛选' : '筛选 · ${query.filterCount}',
                ),
              ),
              PopupMenuButton<FavoriteSort>(
                key: const ValueKey('favorite-sort'),
                tooltip: '收藏排序',
                initialValue: query.sort,
                onOpened: () => FocusManager.instance.primaryFocus?.unfocus(),
                onSelected: (sort) => onChanged(
                  query.copyWith(
                    search: searchController.text.trim(),
                    sort: sort,
                  ),
                ),
                itemBuilder: (_) => [
                  for (final sort in FavoriteSort.values)
                    CheckedPopupMenuItem(
                      key: ValueKey('favorite-sort-${sort.name}'),
                      value: sort,
                      checked: query.sort == sort,
                      child: Text(sort.label),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(query.sort.label),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
              if (!query.isDefault)
                IconButton(
                  key: const ValueKey('favorite-reset'),
                  tooltip: '清除搜索和筛选，恢复默认排序',
                  onPressed: () => onChanged(const FavoriteQuery()),
                  icon: const Icon(Icons.restart_alt),
                ),
            ],
          ),
          if (summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                summary,
                key: const ValueKey('favorite-filter-summary'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _FavoriteFilterSheet extends StatefulWidget {
  const _FavoriteFilterSheet({required this.initialQuery});
  final FavoriteQuery initialQuery;

  @override
  State<_FavoriteFilterSheet> createState() => _FavoriteFilterSheetState();
}

class _FavoriteFilterSheetState extends State<_FavoriteFilterSheet> {
  late FavoriteQuery _draft = widget.initialQuery;

  Widget _group(String title, List<Widget> options) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: options),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '筛选收藏',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(
                key: const ValueKey('favorite-filter-reset'),
                onPressed: () => setState(
                  () => _draft = FavoriteQuery(
                    search: _draft.search,
                    sort: _draft.sort,
                  ),
                ),
                child: const Text('重置'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            key: const ValueKey('favorite-filter-options'),
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '来源',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('favorite-providers-all'),
                    onPressed: () => setState(
                      () => _draft = _draft.copyWith(
                        providers: FavoriteProvider.values,
                      ),
                    ),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    key: const ValueKey('favorite-providers-invert'),
                    onPressed: () => setState(
                      () => _draft = _draft.copyWith(
                        providers: [
                          for (final provider in FavoriteProvider.values)
                            if (!_draft.providers.contains(provider)) provider,
                        ],
                      ),
                    ),
                    child: const Text('反选'),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final provider in FavoriteProvider.values)
                    FilterChip(
                      key: ValueKey('favorite-provider-${provider.name}'),
                      label: Text(provider.label),
                      selected: _draft.providers.contains(provider),
                      onSelected: (selected) => setState(
                        () => _draft = _draft.copyWith(
                          providers: [
                            for (final value in FavoriteProvider.values)
                              if (value == provider
                                  ? selected
                                  : _draft.providers.contains(value))
                                value,
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _group('类型', [
                for (final option in FavoritePublication.values)
                  ChoiceChip(
                    key: ValueKey('favorite-publication-${option.name}'),
                    label: Text(option.label),
                    selected: _draft.publication == option,
                    onSelected: (_) => setState(
                      () => _draft = _draft.copyWith(publication: option),
                    ),
                  ),
              ]),
              _group('分级', [
                for (final option in FavoriteRating.values)
                  ChoiceChip(
                    key: ValueKey('favorite-rating-${option.name}'),
                    label: Text(option.label),
                    selected: _draft.rating == option,
                    onSelected: (_) => setState(
                      () => _draft = _draft.copyWith(rating: option),
                    ),
                  ),
              ]),
              _group('翻译', [
                for (final option in FavoriteTranslation.values)
                  ChoiceChip(
                    key: ValueKey('favorite-translation-${option.name}'),
                    label: Text(option.label),
                    selected: _draft.translation == option,
                    onSelected: (_) => setState(
                      () => _draft = _draft.copyWith(translation: option),
                    ),
                  ),
              ]),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('favorite-filter-cancel'),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('favorite-filter-apply'),
                  onPressed: () => Navigator.pop(context, _draft),
                  child: const Text('应用'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
