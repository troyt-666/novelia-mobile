import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'novelia_gateway.dart';

class NoveliaJsonCodec {
  const NoveliaJsonCodec();

  NoveliaPage<NoveliaNovelOutline> decodeNovelPage(
    Object? json, {
    String? assumedFavoriteFolderId,
  }) {
    final root = _map(json, 'catalog page');
    return NoveliaPage(
      items: _list(root['items'], 'catalog items')
          .map(
            (item) => _decodeNovelOutline(
              _map(item, 'catalog item'),
              assumedFavoriteFolderId: assumedFavoriteFolderId,
            ),
          )
          .toList(growable: false),
      pageCount: _integer(root['pageNumber'], 'pageNumber'),
    );
  }

  NoveliaNovelDetails decodeNovel(NoveliaNovelKey key, Object? json) {
    final root = _map(json, 'novel');
    return NoveliaNovelDetails(
      key: key,
      japaneseTitle: _string(root['titleJp'], 'titleJp'),
      chineseTitle: _optionalString(root['titleZh']),
      authors: _list(root['authors'], 'authors')
          .map((author) {
            final value = _map(author, 'author');
            return NoveliaAuthor(
              name: _string(value['name'], 'author.name'),
              link: _safeWebUri(_optionalString(value['link'])),
            );
          })
          .toList(growable: false),
      publicationType: _optionalString(root['type']),
      attentions: _strings(root['attentions'], 'attentions'),
      keywords: _strings(root['keywords'], 'keywords'),
      points: _optionalInteger(root['points'], 'points'),
      totalCharacters: _optionalInteger(
        root['totalCharacters'],
        'totalCharacters',
      ),
      japaneseIntroduction: _string(root['introductionJp'], 'introductionJp'),
      chineseIntroduction: _optionalString(root['introductionZh']),
      toc: _list(root['toc'], 'toc')
          .map((entry) {
            final value = _map(entry, 'toc item');
            return NoveliaTocEntry(
              japaneseTitle: _string(value['titleJp'], 'toc.titleJp'),
              chineseTitle: _optionalString(value['titleZh']),
              chapterId: _optionalString(value['chapterId']),
              createdAt: _epochSeconds(value['createAt'], 'toc.createAt'),
            );
          })
          .toList(growable: false),
      visited: _optionalInteger(root['visited'], 'visited'),
      syncedAt: _epochSeconds(root['syncAt'], 'syncAt'),
      originalChapters: _integerOrZero(root['jp'], 'jp'),
      baiduChapters: _integerOrZero(root['baidu'], 'baidu'),
      youdaoChapters: _integerOrZero(root['youdao'], 'youdao'),
      gptChapters: _integerOrZero(root['gpt'], 'gpt'),
      sakuraChapters: _integerOrZero(root['sakura'], 'sakura'),
      favoriteFolderId: _optionalString(root['favored']),
    );
  }

  NoveliaChapterPayload decodeChapter(
    NoveliaNovelKey key,
    String chapterId,
    Object? json,
  ) {
    final root = _map(json, 'chapter');
    return NoveliaChapterPayload(
      key: key,
      chapterId: chapterId,
      japaneseTitle: _string(root['titleJp'], 'titleJp'),
      chineseTitle: _optionalString(root['titleZh']),
      novelJapaneseTitle: _optionalString(root['novelTitleJp']),
      novelChineseTitle: _optionalString(root['novelTitleZh']),
      previousChapterId: _optionalString(root['prevId']),
      nextChapterId: _optionalString(root['nextId']),
      originalParagraphs: _strings(root['paragraphs'], 'paragraphs'),
      baiduParagraphs: _optionalStrings(
        root['baiduParagraphs'],
        'baiduParagraphs',
      ),
      youdaoParagraphs: _optionalStrings(
        root['youdaoParagraphs'],
        'youdaoParagraphs',
      ),
      gptParagraphs: _optionalStrings(root['gptParagraphs'], 'gptParagraphs'),
      sakuraParagraphs: _optionalStrings(
        root['sakuraParagraphs'],
        'sakuraParagraphs',
      ),
    );
  }

  NoveliaPage<NoveliaComment> decodeCommentPage(Object? json) {
    final root = _map(json, 'comment page');
    return NoveliaPage(
      items: _list(root['items'], 'comment items')
          .map((item) => _decodeComment(_map(item, 'comment'), depth: 0))
          .toList(growable: false),
      pageCount: _integer(root['pageNumber'], 'pageNumber'),
    );
  }

  NoveliaNovelOutline _decodeNovelOutline(
    Map<String, Object?> value, {
    String? assumedFavoriteFolderId,
  }) {
    return NoveliaNovelOutline(
      key: NoveliaNovelKey(
        providerId: _string(value['providerId'], 'providerId'),
        novelId: _string(value['novelId'], 'novelId'),
      ),
      japaneseTitle: _string(value['titleJp'], 'titleJp'),
      chineseTitle: _optionalString(value['titleZh']),
      publicationType: _optionalString(value['type']),
      extra: _optionalString(value['extra']),
      attentions: _strings(value['attentions'], 'attentions'),
      keywords: _strings(value['keywords'], 'keywords'),
      totalChapters: _integer(value['total'], 'total'),
      originalChapters: _integerOrZero(value['jp'], 'jp'),
      baiduChapters: _integerOrZero(value['baidu'], 'baidu'),
      youdaoChapters: _integerOrZero(value['youdao'], 'youdao'),
      gptChapters: _integerOrZero(value['gpt'], 'gpt'),
      sakuraChapters: _integerOrZero(value['sakura'], 'sakura'),
      updatedAt: _epochSeconds(value['updateAt'], 'updateAt'),
      favoriteFolderId:
          _optionalString(value['favored']) ?? assumedFavoriteFolderId,
    );
  }

  NoveliaComment _decodeComment(
    Map<String, Object?> value, {
    required int depth,
  }) {
    if (depth > 8) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'Novel Comment reply nesting exceeded the supported limit.',
      );
    }
    final user = _map(value['user'], 'comment.user');
    return NoveliaComment(
      id: _string(value['id'], 'comment.id'),
      username: _string(user['username'], 'comment.user.username'),
      content: _string(value['content'], 'comment.content'),
      hidden: value['hidden'] == true,
      createdAt:
          _epochSeconds(value['createAt'], 'comment.createAt') ??
          (throw const NoveliaGatewayException(
            NoveliaGatewayFailureKind.invalidResponse,
            'A Novel Comment was missing its creation time.',
          )),
      replyCount: _integerOrZero(value['numReplies'], 'comment.numReplies'),
      replies: _optionalList(value['replies'], 'comment.replies')
          .map(
            (reply) =>
                _decodeComment(_map(reply, 'comment reply'), depth: depth + 1),
          )
          .toList(growable: false),
    );
  }

  static Map<String, Object?> _map(Object? value, String field) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry('$key', value));
    }
    throw NoveliaGatewayException(
      NoveliaGatewayFailureKind.invalidResponse,
      'Expected $field to be an object.',
    );
  }

  static List<Object?> _list(Object? value, String field) {
    if (value is List) return value;
    throw NoveliaGatewayException(
      NoveliaGatewayFailureKind.invalidResponse,
      'Expected $field to be a list.',
    );
  }

  static List<Object?> _optionalList(Object? value, String field) {
    if (value == null) return const [];
    return _list(value, field);
  }

  static String _string(Object? value, String field) {
    if (value is String) return value;
    throw NoveliaGatewayException(
      NoveliaGatewayFailureKind.invalidResponse,
      'Expected $field to be text.',
    );
  }

  static String? _optionalString(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'Expected an optional text field to be text.',
      );
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : value;
  }

  static int _integer(Object? value, String field) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    throw NoveliaGatewayException(
      NoveliaGatewayFailureKind.invalidResponse,
      'Expected $field to be an integer.',
    );
  }

  static int? _optionalInteger(Object? value, String field) {
    if (value == null) return null;
    return _integer(value, field);
  }

  static int _integerOrZero(Object? value, String field) {
    if (value == null) return 0;
    return _integer(value, field);
  }

  static List<String> _strings(Object? value, String field) {
    return _list(
      value,
      field,
    ).map((item) => _string(item, field)).toList(growable: false);
  }

  static List<String> _optionalStrings(Object? value, String field) {
    if (value == null) return const [];
    return _strings(value, field);
  }

  static DateTime? _epochSeconds(Object? value, String field) {
    if (value == null) return null;
    final seconds = _integer(value, field);
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  static Uri? _safeWebUri(String? value) {
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    return uri;
  }
}

class HttpNoveliaGateway implements NoveliaGateway {
  HttpNoveliaGateway({
    Uri? baseUri,
    HttpClient? client,
    this.accessTokenProvider,
    this.requestTimeout = const Duration(seconds: 20),
    this.maximumResponseBytes = 32 * 1024 * 1024,
    this.codec = const NoveliaJsonCodec(),
  }) : baseUri = baseUri ?? Uri.parse('https://n.novelia.cc/api/'),
       _client = client ?? HttpClient(),
       _ownsClient = client == null;

  final Uri baseUri;
  final Duration requestTimeout;
  final int maximumResponseBytes;
  final HttpClient _client;
  final bool _ownsClient;
  final NoveliaAccessTokenProvider? accessTokenProvider;
  final NoveliaJsonCodec codec;

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listNovels(
    NoveliaCatalogQuery query,
  ) async {
    final json = await _getJson('novel', query.toQueryParameters());
    return codec.decodeNovelPage(json);
  }

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listRankings(
    NoveliaRankingQuery query,
  ) async {
    final json = await _getJson(
      'novel/rank/${_segment(query.providerId)}',
      query.parameters,
    );
    return codec.decodeNovelPage(json);
  }

  @override
  Future<NoveliaNovelDetails> getNovel(NoveliaNovelKey key) async {
    final json = await _getJson(
      'novel/${_segment(key.providerId)}/${_segment(key.novelId)}',
    );
    return codec.decodeNovel(key, json);
  }

  @override
  Future<NoveliaChapterPayload> getChapter(
    NoveliaNovelKey key,
    String chapterId,
  ) async {
    final json = await _getJson(
      'novel/${_segment(key.providerId)}/${_segment(key.novelId)}/chapter/${_segment(chapterId)}',
    );
    return codec.decodeChapter(key, chapterId, json);
  }

  @override
  Future<NoveliaPage<NoveliaComment>> listComments(
    NoveliaNovelKey key, {
    int page = 0,
    int pageSize = 10,
  }) async {
    final json = await _getJson('comment', {
      'page': '$page',
      'pageSize': '$pageSize',
      'site': key.commentSite,
    });
    return codec.decodeCommentPage(json);
  }

  void close() {
    if (_ownsClient) _client.close(force: true);
  }

  Future<Object?> _getJson(
    String relativePath, [
    Map<String, String>? query,
  ]) async {
    final resolved = baseUri.resolve(relativePath);
    final uri = query == null
        ? resolved
        : resolved.replace(queryParameters: query);
    try {
      final request = await _client.getUrl(uri).timeout(requestTimeout);
      request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
      final token = await accessTokenProvider?.call();
      if (token != null && token.trim().isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close().timeout(requestTimeout);
      final bytes = <int>[];
      await for (final chunk in response.timeout(requestTimeout)) {
        if (bytes.length + chunk.length > maximumResponseBytes) {
          throw const NoveliaGatewayException(
            NoveliaGatewayFailureKind.invalidResponse,
            'The service response exceeded the configured size limit.',
          );
        }
        bytes.addAll(chunk);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _statusFailure(response.statusCode);
      }
      try {
        return jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const NoveliaGatewayException(
          NoveliaGatewayFailureKind.invalidResponse,
          'The service returned malformed JSON.',
        );
      }
    } on NoveliaGatewayException {
      rethrow;
    } on TimeoutException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.timeout,
        'The service request timed out.',
      );
    } on SocketException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The service could not be reached.',
      );
    } on TlsException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The secure service connection failed.',
      );
    } on HttpException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The service request failed.',
      );
    }
  }

  static NoveliaGatewayException _statusFailure(int statusCode) {
    return switch (statusCode) {
      401 => const NoveliaGatewayException(
        NoveliaGatewayFailureKind.authenticationRequired,
        'This service operation requires a Reader Account.',
        statusCode: 401,
      ),
      403 => const NoveliaGatewayException(
        NoveliaGatewayFailureKind.forbidden,
        'The service refused this operation.',
        statusCode: 403,
      ),
      404 => const NoveliaGatewayException(
        NoveliaGatewayFailureKind.notFound,
        'The requested content was not found.',
        statusCode: 404,
      ),
      >= 500 => NoveliaGatewayException(
        NoveliaGatewayFailureKind.server,
        'The service returned a server error.',
        statusCode: statusCode,
      ),
      _ => NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'The service returned an unexpected status.',
        statusCode: statusCode,
      ),
    };
  }

  static String _segment(String value) => Uri.encodeComponent(value);
}
