import 'dart:async';

import 'package:flutter/material.dart';

import '../discover/catalog_card.dart';
import '../discover/catalog_models.dart';

/// Shared, bounded read-only comments beneath a novel's catalog or volumes.
class NovelCommentsSection extends StatefulWidget {
  const NovelCommentsSection({
    this.loadPage,
    this.comments = const [],
    this.commentsPerPage = 2,
    super.key,
  }) : assert(commentsPerPage > 0);

  final Future<NovelCommentPage> Function(int pageNumber)? loadPage;
  final List<NovelComment> comments;
  final int commentsPerPage;

  @override
  State<NovelCommentsSection> createState() => _NovelCommentsSectionState();
}

class _NovelCommentsSectionState extends State<NovelCommentsSection> {
  int _commentPage = 0;
  NovelCommentPage? _loadedCommentPage;
  Object? _commentError;
  bool _commentsLoading = false;
  int _commentRequestGeneration = 0;
  int _requestedCommentPage = 1;
  bool get _usesRemoteComments => widget.loadPage != null;

  @override
  void initState() {
    super.initState();
    if (_usesRemoteComments) {
      _commentsLoading = true;
      unawaited(_loadCommentPage(1, announceLoading: false));
    }
  }

  int get _commentPageCount {
    if (_usesRemoteComments) return _loadedCommentPage?.totalPages ?? 0;
    if (widget.comments.isEmpty) return 0;
    return (widget.comments.length / widget.commentsPerPage).ceil();
  }

  List<NovelComment> get _visibleComments {
    if (_usesRemoteComments) return _loadedCommentPage?.comments ?? const [];
    final start = _commentPage * widget.commentsPerPage;
    final end = (start + widget.commentsPerPage).clamp(
      start,
      widget.comments.length,
    );
    return widget.comments.sublist(start, end);
  }

  String get _commentSummary {
    if (!_usesRemoteComments) return '${widget.comments.length} 条';
    if (_commentsLoading) return '加载中';
    if (_commentError != null) return '加载失败';
    final page = _loadedCommentPage;
    if (page == null) return '—';
    final totalComments = page.totalComments;
    if (totalComments != null) return '$totalComments 条';
    return page.totalPages == 0 ? '评论已加载' : '共 ${page.totalPages} 页';
  }

  Future<void> _loadCommentPage(
    int pageNumber, {
    bool announceLoading = true,
  }) async {
    final loader = widget.loadPage;
    if (loader == null) {
      setState(() => _commentPage = pageNumber - 1);
      return;
    }
    final generation = ++_commentRequestGeneration;
    _requestedCommentPage = pageNumber;
    if (announceLoading && mounted) {
      setState(() {
        _commentsLoading = true;
        _commentError = null;
        _loadedCommentPage = null;
      });
    }
    try {
      final page = await loader(pageNumber);
      if (!mounted || generation != _commentRequestGeneration) return;
      if (page.pageNumber != pageNumber) {
        throw StateError('Comment loader returned a different page.');
      }
      setState(() {
        _commentPage = page.pageNumber - 1;
        _loadedCommentPage = page;
        _commentError = null;
        _commentsLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _commentRequestGeneration) return;
      setState(() {
        _loadedCommentPage = null;
        _commentError = error;
        _commentsLoading = false;
      });
    }
  }

  List<Widget> _buildCommentSlivers(BuildContext context) {
    if (_commentsLoading) {
      return const [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 36),
          sliver: SliverToBoxAdapter(child: _CommentsLoadingState()),
        ),
      ];
    }
    if (_commentError != null) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 36),
          sliver: SliverToBoxAdapter(
            child: _CommentsErrorState(
              onRetry: () => _loadCommentPage(_requestedCommentPage),
            ),
          ),
        ),
      ];
    }
    if (_visibleComments.isEmpty) {
      return const [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(20, 10, 20, 30),
          sliver: SliverToBoxAdapter(child: Text('暂无评论')),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList.separated(
          key: ValueKey('comments-page-${_commentPage + 1}'),
          itemCount: _visibleComments.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) =>
              _CommentCard(comment: _visibleComments[index]),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
        sliver: SliverToBoxAdapter(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.outlined(
                key: const ValueKey('comments-previous-page'),
                tooltip: '上一页',
                onPressed: _commentPage == 0
                    ? null
                    : () => _loadCommentPage(_commentPage),
                icon: const Icon(Icons.chevron_left),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '第 ${_commentPage + 1} / $_commentPageCount 页',
                  key: const ValueKey('comments-page-indicator'),
                ),
              ),
              IconButton.outlined(
                key: const ValueKey('comments-next-page'),
                tooltip: '下一页',
                onPressed: _commentPage >= _commentPageCount - 1
                    ? null
                    : () => _loadCommentPage(_commentPage + 2),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 30, 20, 12),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '读者评论',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                _commentSummary,
                key: const ValueKey('comments-summary'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
        ),
      ),
      ..._buildCommentSlivers(context),
    ],
  );
}

class _CommentsLoadingState extends StatelessWidget {
  const _CommentsLoadingState();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('comments-page-loading'),
      liveRegion: true,
      label: '正在加载评论',
      child: const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }
}

class _CommentsErrorState extends StatelessWidget {
  const _CommentsErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('comments-page-error'),
      liveRegion: true,
      label: '评论加载失败',
      child: Card.outlined(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              const Text('无法加载这一页评论'),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('retry-comments-page'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentCard extends StatelessWidget {
  const _CommentCard({required this.comment});

  final NovelComment comment;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card.outlined(
      key: ValueKey('novel-comment-${comment.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  child: Text(
                    comment.author.isEmpty
                        ? '?'
                        : comment.author.characters.first,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    comment.author,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatCatalogDate(comment.createdAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(comment.body, style: const TextStyle(height: 1.55)),
            for (final reply in comment.replies) ...[
              const SizedBox(height: 11),
              Container(
                key: ValueKey('comment-reply-${reply.id}'),
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reply.author,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(reply.body, style: const TextStyle(height: 1.45)),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
