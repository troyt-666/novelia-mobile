import 'package:flutter/material.dart';

import 'catalog_card.dart';
import 'catalog_models.dart';

class CatalogSearchResultsScreen extends StatelessWidget {
  const CatalogSearchResultsScreen({
    required this.title,
    required this.novels,
    required this.onOpenNovel,
    super.key,
  });

  final String title;
  final List<CatalogNovel> novels;
  final ValueChanged<CatalogNovel> onOpenNovel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('catalog-search-results-screen'),
      appBar: AppBar(title: Text(title)),
      body: novels.isEmpty
          ? const Center(child: Text('没有匹配的小说'))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              itemCount: novels.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final novel = novels[index];
                return CatalogNovelCard(
                  novel: novel,
                  onOpen: () => onOpenNovel(novel),
                );
              },
            ),
    );
  }
}
