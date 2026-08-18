import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../../core/account/account_sync_models.dart';
import 'http_novelia_gateway.dart';
import 'novelia_account_gateway.dart';
import 'novelia_gateway.dart';

class HttpNoveliaAccountGateway implements NoveliaAccountGateway {
  HttpNoveliaAccountGateway({
    required this.accessTokenProvider,
    Uri? baseUri,
    HttpClient? client,
    this.requestTimeout = const Duration(seconds: 20),
    this.maximumResponseBytes = 2 * 1024 * 1024,
    this.codec = const NoveliaJsonCodec(),
    this.debugDiagnosticSink,
  }) : baseUri = baseUri ?? Uri.parse('https://n.novelia.cc/api/'),
       _client = client ?? HttpClient(),
       _ownsClient = client == null;

  final AccountAccessTokenProvider accessTokenProvider;
  final Uri baseUri;
  final Duration requestTimeout;
  final int maximumResponseBytes;
  final NoveliaJsonCodec codec;
  final void Function(String message)? debugDiagnosticSink;
  final HttpClient _client;
  final bool _ownsClient;

  @override
  Future<List<RemoteFavoriteFolder>> listFavoriteFolders() async {
    final response = await _request('GET', 'user/favored');
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.body));
    } on Object {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'Favorite folders were malformed.',
      );
    }
    if (decoded is! Map || decoded['favoredWeb'] is! List) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'Favorite folders were missing.',
      );
    }
    final folders = <RemoteFavoriteFolder>[];
    final ids = <String>{};
    for (final item in decoded['favoredWeb'] as List) {
      if (item is! Map || item['id'] is! String || item['title'] is! String) {
        throw const NoveliaGatewayException(
          NoveliaGatewayFailureKind.invalidResponse,
          'A favorite folder was malformed.',
        );
      }
      final id = (item['id'] as String).trim();
      final title = (item['title'] as String).trim();
      if (id.isEmpty || title.isEmpty || !ids.add(id)) {
        throw const NoveliaGatewayException(
          NoveliaGatewayFailureKind.invalidResponse,
          'A favorite folder identity was invalid.',
        );
      }
      folders.add(RemoteFavoriteFolder(id: id, title: title));
    }
    return List.unmodifiable(folders);
  }

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listFavoriteWebNovels({
    required String folderId,
    int page = 0,
    int pageSize = 30,
  }) async {
    _validatePage(page, pageSize);
    final response = await _request(
      'GET',
      'user/favored-web/${_segment(folderId)}',
      query: {'page': '$page', 'pageSize': '$pageSize'},
    );
    return codec.decodeNovelPage(_decodeJson(response.body, 'Favorites page'));
  }

  @override
  Future<NoveliaPage<NoveliaNovelOutline>> listReadHistory({
    int page = 0,
    int pageSize = 30,
  }) async {
    _validatePage(page, pageSize);
    final response = await _request(
      'GET',
      'user/read-history',
      query: {'page': '$page', 'pageSize': '$pageSize'},
    );
    return codec.decodeNovelPage(
      _decodeJson(response.body, 'Reading History page'),
    );
  }

  @override
  Future<RemoteFavoriteFolder> createFavoriteFolder(String title) async {
    final normalized = title.trim();
    if (normalized.isEmpty) throw ArgumentError.value(title, 'title');
    final response = await _request(
      'POST',
      'user/favored-web',
      json: {'title': normalized},
      retryAfterRefresh: false,
    );
    final id = utf8.decode(response.body).trim();
    if (id.isEmpty) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'Favorite folder creation returned no ID.',
      );
    }
    return RemoteFavoriteFolder(id: id, title: normalized);
  }

  @override
  Future<void> favoriteWebNovel({
    required String folderId,
    required String providerId,
    required String novelId,
  }) async {
    await _request(
      'PUT',
      'user/favored-web/${_segment(folderId)}/${_segment(providerId)}/${_segment(novelId)}',
    );
  }

  @override
  Future<void> unfavoriteWebNovel({
    required String folderId,
    required String providerId,
    required String novelId,
  }) async {
    await _request(
      'DELETE',
      'user/favored-web/${_segment(folderId)}/${_segment(providerId)}/${_segment(novelId)}',
    );
  }

  @override
  Future<void> updateReadHistory({
    required String providerId,
    required String novelId,
    required String chapterId,
  }) async {
    await _request(
      'PUT',
      'user/read-history/${_segment(providerId)}/${_segment(novelId)}',
      textBody: chapterId,
    );
  }

  void close() {
    if (_ownsClient) _client.close(force: true);
  }

  Future<_AccountResponse> _request(
    String method,
    String relativePath, {
    Map<String, Object?>? json,
    String? textBody,
    Map<String, String>? query,
    bool retryAfterRefresh = true,
  }) async {
    final token = await accessTokenProvider(forceRefresh: false);
    if (token == null || token.isEmpty) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.authenticationRequired,
        'A Reader Account is required.',
      );
    }
    var response = await _send(
      method,
      relativePath,
      token: token,
      json: json,
      textBody: textBody,
      query: query,
    );
    if (response.statusCode == 401 && retryAfterRefresh) {
      final refreshed = await accessTokenProvider(forceRefresh: true);
      if (refreshed != null && refreshed.isNotEmpty) {
        response = await _send(
          method,
          relativePath,
          token: refreshed,
          json: json,
          textBody: textBody,
          query: query,
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _statusFailure(response.statusCode);
    }
    return response;
  }

  Future<_AccountResponse> _send(
    String method,
    String relativePath, {
    required String token,
    Map<String, Object?>? json,
    String? textBody,
    Map<String, String>? query,
  }) async {
    try {
      final resolved = baseUri.resolve(relativePath);
      final uri = query == null
          ? resolved
          : resolved.replace(queryParameters: query);
      final request = await _client
          .openUrl(method, uri)
          .timeout(requestTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (json != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        request.add(utf8.encode(jsonEncode(json)));
      } else if (textBody != null) {
        // The public client sends Reading History chapter IDs as an untyped
        // body. Match it exactly instead of inventing a media type.
        request.add(utf8.encode(textBody));
      }
      final response = await request.close().timeout(requestTimeout);
      final body = <int>[];
      await for (final chunk in response.timeout(requestTimeout)) {
        if (body.length + chunk.length > maximumResponseBytes) {
          throw const NoveliaGatewayException(
            NoveliaGatewayFailureKind.invalidResponse,
            'Account response exceeded the configured size limit.',
          );
        }
        body.addAll(chunk);
      }
      assert(() {
        _debugTrace({
          'event': 'response',
          'operation': _operationName(method, relativePath),
          'status': response.statusCode,
          'contentType': response.headers.contentType?.toString(),
          'body': _describeBody(body),
        });
        return true;
      }());
      return _AccountResponse(statusCode: response.statusCode, body: body);
    } on NoveliaGatewayException {
      rethrow;
    } on TimeoutException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.timeout,
        'The account request timed out.',
      );
    } on SocketException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The account service could not be reached.',
      );
    } on TlsException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The secure account connection failed.',
      );
    } on HttpException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The account request failed.',
      );
    }
  }

  static NoveliaGatewayException _statusFailure(int statusCode) {
    return switch (statusCode) {
      401 => const NoveliaGatewayException(
        NoveliaGatewayFailureKind.authenticationRequired,
        'The account session has expired.',
        statusCode: 401,
      ),
      403 => const NoveliaGatewayException(
        NoveliaGatewayFailureKind.forbidden,
        'The account operation was refused.',
        statusCode: 403,
      ),
      404 => const NoveliaGatewayException(
        NoveliaGatewayFailureKind.notFound,
        'The account resource was not found.',
        statusCode: 404,
      ),
      >= 500 => NoveliaGatewayException(
        NoveliaGatewayFailureKind.server,
        'The account service returned a server error.',
        statusCode: statusCode,
      ),
      _ => NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'The account service returned an unexpected status.',
        statusCode: statusCode,
      ),
    };
  }

  static String _segment(String value) {
    if (value.trim().isEmpty) throw ArgumentError.value(value, 'identifier');
    return Uri.encodeComponent(value);
  }

  void _debugTrace(Map<String, Object?> fields) {
    final message = jsonEncode(fields);
    if (debugDiagnosticSink case final sink?) {
      sink(message);
    } else {
      developer.log(message, name: 'novelia.account');
      stderr.writeln('novelia.account $message');
    }
  }

  static String _operationName(String method, String path) {
    if (path == 'user/favored') return 'list_favorite_folders';
    if (path == 'user/favored-web') return 'create_favorite_folder';
    if (method == 'GET' && path.startsWith('user/favored-web/')) {
      return 'list_favorite_novels';
    }
    if (path.startsWith('user/favored-web/')) {
      return method == 'DELETE' ? 'unfavorite_novel' : 'favorite_novel';
    }
    if (method == 'GET' && path == 'user/read-history') {
      return 'list_read_history';
    }
    if (path.startsWith('user/read-history/')) return 'update_read_history';
    return 'account_request';
  }

  static Map<String, Object?> _describeBody(List<int> body) {
    final text = utf8.decode(body, allowMalformed: true).trim();
    if (text.isEmpty) return const {'kind': 'empty'};
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const {'kind': 'text'};
    }
    return {'kind': 'json', 'schema': _jsonSchema(decoded, depth: 0)};
  }

  static Object _jsonSchema(Object? value, {required int depth}) {
    if (depth >= 4) return _valueType(value);
    if (value is Map) {
      final entries = <String, Object>{};
      for (final entry in value.entries) {
        entries[entry.key.toString()] = _jsonSchema(
          entry.value,
          depth: depth + 1,
        );
      }
      return Map.fromEntries(
        entries.entries.toList()
          ..sort((left, right) => left.key.compareTo(right.key)),
      );
    }
    if (value is List) {
      return <String, Object>{
        'type': 'array',
        'item': value.isEmpty
            ? 'unknown'
            : _jsonSchema(value.first, depth: depth + 1),
      };
    }
    return _valueType(value);
  }

  static String _valueType(Object? value) => switch (value) {
    null => 'null',
    String() => 'string',
    bool() => 'boolean',
    int() => 'integer',
    double() => 'number',
    List() => 'array',
    Map() => 'object',
    _ => value.runtimeType.toString(),
  };

  static Object? _decodeJson(List<int> body, String label) {
    try {
      return jsonDecode(utf8.decode(body));
    } on Object {
      throw NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        '$label was malformed.',
      );
    }
  }

  static void _validatePage(int page, int pageSize) {
    if (page < 0) throw ArgumentError.value(page, 'page');
    if (pageSize <= 0 || pageSize > 100) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
  }
}

class _AccountResponse {
  const _AccountResponse({required this.statusCode, required this.body});

  final int statusCode;
  final List<int> body;
}
