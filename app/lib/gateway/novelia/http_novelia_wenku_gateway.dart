import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'novelia_gateway.dart';
import 'novelia_request_policy.dart';
import 'novelia_wenku_gateway.dart';

class WenkuJsonCodec {
  const WenkuJsonCodec();

  NoveliaPage<WenkuNovelSummary> decodeNovelPage(Object? json) {
    final root = _map(json, 'Wenku catalog page');
    return NoveliaPage(
      items: _list(root['items'], 'Wenku catalog items')
          .map((item) {
            final value = _map(item, 'Wenku catalog item');
            return WenkuNovelSummary(
              id: _string(value['id'], 'id'),
              japaneseTitle: _string(value['title'], 'title'),
              chineseTitle: _string(value['titleZh'], 'titleZh'),
              coverUri: _safeHttpsUri(value['cover']),
            );
          })
          .toList(growable: false),
      pageCount: _integer(root['pageNumber'], 'pageNumber'),
    );
  }

  WenkuNovelDetails decodeNovel(String novelId, Object? json) {
    final root = _map(json, 'Wenku novel');
    return WenkuNovelDetails(
      id: novelId,
      japaneseTitle: _string(root['title'], 'title'),
      chineseTitle: _string(root['titleZh'], 'titleZh'),
      coverUri: _safeHttpsUri(root['cover']),
      authors: _strings(root['authors'], 'authors'),
      artists: _strings(root['artists'], 'artists'),
      keywords: _strings(root['keywords'], 'keywords'),
      publisher: _optionalString(root['publisher']),
      imprint: _optionalString(root['imprint']),
      level: _string(root['level'], 'level'),
      introduction: _string(root['introduction'], 'introduction'),
      publishedVolumes: _list(root['volumes'], 'volumes')
          .map((item) {
            final value = _map(item, 'published volume');
            final publishedSeconds = _optionalInteger(
              value['publishAt'],
              'publishAt',
            );
            return WenkuPublishedVolume(
              asin: _string(value['asin'], 'asin'),
              japaneseTitle: _string(value['title'], 'volume.title'),
              chineseTitle: _optionalString(value['titleZh']),
              coverUri: _safeHttpsUri(value['coverHires'] ?? value['cover']),
              publishedAt: publishedSeconds == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      publishedSeconds * 1000,
                      isUtc: true,
                    ),
            );
          })
          .toList(growable: false),
      japaneseEpubs: _list(root['volumeJp'], 'volumeJp')
          .map((item) {
            final value = _map(item, 'Japanese EPUB volume');
            return WenkuEpubVolume(
              volumeId: _string(value['volumeId'], 'volumeId'),
              totalParagraphs: _integer(value['total'], 'total'),
              translationCounts: {
                WenkuTranslationProvider.baidu: _integerOrZero(
                  value['baidu'],
                  'baidu',
                ),
                WenkuTranslationProvider.youdao: _integerOrZero(
                  value['youdao'],
                  'youdao',
                ),
                WenkuTranslationProvider.gpt: _integerOrZero(
                  value['gpt'],
                  'gpt',
                ),
                WenkuTranslationProvider.sakura: _integerOrZero(
                  value['sakura'],
                  'sakura',
                ),
              },
            );
          })
          .toList(growable: false),
      chineseEpubIds: _strings(root['volumeZh'], 'volumeZh'),
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
        'Expected optional text to be text.',
      );
    }
    return value.trim().isEmpty ? null : value;
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

  static int? _optionalInteger(Object? value, String field) =>
      value == null ? null : _integer(value, field);

  static int _integerOrZero(Object? value, String field) =>
      value == null ? 0 : _integer(value, field);

  static List<String> _strings(Object? value, String field) => _list(
    value,
    field,
  ).map((item) => _string(item, field)).toList(growable: false);

  static Uri? _safeHttpsUri(Object? value) {
    final text = _optionalString(value);
    if (text == null) return null;
    final uri = Uri.tryParse(text);
    return uri != null && uri.scheme == 'https' ? uri : null;
  }
}

class HttpNoveliaWenkuGateway implements NoveliaWenkuGateway {
  HttpNoveliaWenkuGateway({
    Uri? baseUri,
    HttpClient? client,
    this.requestTimeout = const Duration(seconds: 30),
    this.maximumEpubBytes = 64 * 1024 * 1024,
    this.codec = const WenkuJsonCodec(),
  }) : baseUri = baseUri ?? Uri.parse('https://n.novelia.cc/api/'),
       _client = client ?? HttpClient(),
       _ownsClient = client == null;

  final Uri baseUri;
  final Duration requestTimeout;
  final int maximumEpubBytes;
  final WenkuJsonCodec codec;
  final HttpClient _client;
  final bool _ownsClient;

  @override
  Future<NoveliaPage<WenkuNovelSummary>> listNovels(
    WenkuCatalogQuery query,
  ) async => codec.decodeNovelPage(
    await _getJson('wenku', query: query.toQueryParameters()),
  );

  @override
  Future<WenkuNovelDetails> getNovel(String novelId) async =>
      codec.decodeNovel(novelId, await _getJson('wenku/${_segment(novelId)}'));

  @override
  Future<Uint8List> downloadEpub(
    WenkuEpubRequest request, {
    void Function(int bytesReceived, int? totalBytes)? onReceiveProgress,
    WenkuEpubDownloadCancellationToken? cancellationToken,
  }) async {
    if (request.providers.isEmpty) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'At least one translation provider is required.',
      );
    }
    final endpoint = baseUri
        .resolve(
          'wenku/${_segment(request.novelId)}/file/${_segment(request.volumeId)}',
        )
        .replace(
          queryParameters: <String, dynamic>{
            'mode': request.order.serviceCode,
            'translationsMode': 'priority',
            'translations': [
              for (final provider in request.providers) provider.serviceCode,
            ],
            'filename': request.filename,
          },
        );
    try {
      cancellationToken?.throwIfCancelled();
      final redirect = await _open(
        endpoint,
        accept: 'application/epub+zip',
        cancellationToken: cancellationToken,
      );
      if (redirect.statusCode != HttpStatus.found &&
          redirect.statusCode != HttpStatus.temporaryRedirect) {
        await redirect.drain<void>();
        throw _statusFailure(redirect.statusCode);
      }
      final location = redirect.headers.value(HttpHeaders.locationHeader);
      await redirect.drain<void>();
      if (location == null) {
        throw const NoveliaGatewayException(
          NoveliaGatewayFailureKind.invalidResponse,
          'The EPUB response omitted its download location.',
        );
      }
      final target = endpoint.resolve(location);
      if (target.origin != endpoint.origin ||
          !isAllowedNoveliaRequestUri(target) ||
          !target.path.startsWith('/files-temp/wenku/')) {
        throw const NoveliaGatewayException(
          NoveliaGatewayFailureKind.invalidResponse,
          'The EPUB download redirect was not allowed.',
        );
      }
      cancellationToken?.throwIfCancelled();
      final response = await _open(
        target,
        accept: 'application/epub+zip',
        cancellationToken: cancellationToken,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw _statusFailure(response.statusCode);
      }
      return _readBytes(
        response,
        maximumBytes: maximumEpubBytes,
        onReceiveProgress: onReceiveProgress,
        cancellationToken: cancellationToken,
      );
    } on WenkuEpubDownloadCancelledException {
      rethrow;
    } on NoveliaGatewayException {
      rethrow;
    } on TimeoutException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.timeout,
        'The Wenku request timed out.',
      );
    } on SocketException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The Wenku service could not be reached.',
      );
    } on TlsException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The secure Wenku connection failed.',
      );
    } on HttpException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The Wenku request failed.',
      );
    }
  }

  void close() {
    if (_ownsClient) _client.close(force: true);
  }

  Future<Object?> _getJson(
    String relativePath, {
    Map<String, String>? query,
  }) async {
    final resolved = baseUri.resolve(relativePath);
    final uri = query == null
        ? resolved
        : resolved.replace(queryParameters: query);
    try {
      final response = await _open(uri, accept: ContentType.json.mimeType);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw _statusFailure(response.statusCode);
      }
      final bytes = await _readBytes(response, maximumBytes: 4 * 1024 * 1024);
      try {
        return jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const NoveliaGatewayException(
          NoveliaGatewayFailureKind.invalidResponse,
          'The Wenku service returned malformed JSON.',
        );
      }
    } on NoveliaGatewayException {
      rethrow;
    } on TimeoutException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.timeout,
        'The Wenku request timed out.',
      );
    } on SocketException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The Wenku service could not be reached.',
      );
    } on TlsException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The secure Wenku connection failed.',
      );
    } on HttpException {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.network,
        'The Wenku request failed.',
      );
    }
  }

  Future<HttpClientResponse> _open(
    Uri uri, {
    required String accept,
    WenkuEpubDownloadCancellationToken? cancellationToken,
  }) async {
    if (!isAllowedNoveliaRequestUri(uri)) {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'The Wenku service host is not allowed.',
      );
    }
    cancellationToken?.throwIfCancelled();
    final request = await _client.getUrl(uri).timeout(requestTimeout);
    cancellationToken?.throwIfCancelled();
    pinNoveliaHttpRequest(request);
    request.headers.set(HttpHeaders.acceptHeader, accept);
    final removeCancellationListener = cancellationToken?.addListener(
      () => request.abort(const WenkuEpubDownloadCancelledException()),
    );
    try {
      return await request.close().timeout(requestTimeout);
    } finally {
      removeCancellationListener?.call();
    }
  }

  Future<Uint8List> _readBytes(
    HttpClientResponse response, {
    required int maximumBytes,
    void Function(int bytesReceived, int? totalBytes)? onReceiveProgress,
    WenkuEpubDownloadCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final advertisedLength = response.contentLength;
    if (advertisedLength > maximumBytes) {
      await response.drain<void>();
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'The Wenku response exceeded the configured size limit.',
      );
    }
    final builder = BytesBuilder(copy: false);
    final completion = Completer<Uint8List>();
    var count = 0;
    late final StreamSubscription<List<int>> subscription;

    void fail(Object error, [StackTrace? stackTrace]) {
      if (!completion.isCompleted) {
        completion.completeError(error, stackTrace ?? StackTrace.current);
      }
    }

    subscription = response
        .timeout(requestTimeout)
        .listen(
          (chunk) {
            count += chunk.length;
            if (count > maximumBytes) {
              fail(
                const NoveliaGatewayException(
                  NoveliaGatewayFailureKind.invalidResponse,
                  'The Wenku response exceeded the configured size limit.',
                ),
              );
              unawaited(subscription.cancel());
              return;
            }
            builder.add(chunk);
            onReceiveProgress?.call(
              count,
              advertisedLength >= 0 ? advertisedLength : null,
            );
          },
          onError: (Object error, StackTrace stackTrace) =>
              fail(error, stackTrace),
          onDone: () {
            if (!completion.isCompleted) {
              completion.complete(builder.takeBytes());
            }
          },
          cancelOnError: true,
        );
    final removeCancellationListener = cancellationToken?.addListener(() {
      unawaited(subscription.cancel());
      fail(const WenkuEpubDownloadCancelledException());
    });
    try {
      return await completion.future;
    } finally {
      removeCancellationListener?.call();
    }
  }

  static NoveliaGatewayException _statusFailure(int statusCode) =>
      NoveliaGatewayException(
        statusCode == 404
            ? NoveliaGatewayFailureKind.notFound
            : statusCode >= 500
            ? NoveliaGatewayFailureKind.server
            : NoveliaGatewayFailureKind.invalidResponse,
        'The Wenku service returned HTTP $statusCode.',
        statusCode: statusCode,
      );

  static String _segment(String value) => Uri.encodeComponent(value);
}
