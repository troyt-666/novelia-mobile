import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../../core/account/account_models.dart';
import 'novelia_auth_gateway.dart';
import 'novelia_request_policy.dart';

class HttpNoveliaAuthGateway implements NoveliaAuthGateway {
  HttpNoveliaAuthGateway({
    Uri? baseUri,
    HttpClient? client,
    this.appId = 'n',
    this.requestTimeout = const Duration(seconds: 15),
    this.maximumResponseBytes = 64 * 1024,
    this.debugDiagnosticSink,
  }) : baseUri = baseUri ?? Uri.parse('https://auth.novelia.cc/api/v1/'),
       _client = client ?? HttpClient(),
       _ownsClient = client == null;

  final Uri baseUri;
  final String appId;
  final Duration requestTimeout;
  final int maximumResponseBytes;
  final void Function(String message)? debugDiagnosticSink;
  final HttpClient _client;
  final bool _ownsClient;

  @override
  Future<StoredAccountSession> login({
    required String username,
    required String password,
  }) async {
    final normalizedUsername = username.trim();
    if (normalizedUsername.isEmpty || password.isEmpty) {
      throw const NoveliaAuthException(
        NoveliaAuthFailureKind.invalidCredentials,
        'Username and password are required.',
      );
    }
    final response = await _post(
      'auth/login',
      json: {
        'app': appId,
        'username': normalizedUsername,
        'password': password,
      },
      operation: _AuthOperation.login,
    );
    final cookieHeader = _mergeCookies('', response.cookies);
    if (cookieHeader.isEmpty) {
      throw const NoveliaAuthException(
        NoveliaAuthFailureKind.invalidResponse,
        'Login did not establish a refresh session.',
        diagnosticCode: 'login_missing_refresh_cookie',
      );
    }
    return _refreshWithCookie(cookieHeader);
  }

  @override
  Future<StoredAccountSession> refresh(StoredAccountSession session) {
    return _refreshWithCookie(session.cookieHeader);
  }

  Future<StoredAccountSession> _refreshWithCookie(String cookieHeader) async {
    final response = await _post(
      'auth/refresh',
      query: {'app': appId},
      cookieHeader: cookieHeader,
      operation: _AuthOperation.refresh,
    );
    final accessToken = utf8.decode(response.body).trim();
    try {
      decodeNoveliaAccessToken(accessToken);
    } on FormatException catch (error) {
      assert(() {
        _debugTrace({
          'event': 'token_validation_failed',
          'operation': _AuthOperation.refresh.name,
          'reason': error.message,
          'body': _describeBody(response.body),
        });
        return true;
      }());
      throw NoveliaAuthException(
        NoveliaAuthFailureKind.invalidResponse,
        'Refresh returned an invalid access token.',
        diagnosticCode: 'refresh_invalid_access_token',
      );
    }
    final refreshedCookie = _mergeCookies(cookieHeader, response.cookies);
    if (refreshedCookie.isEmpty) {
      throw const NoveliaAuthException(
        NoveliaAuthFailureKind.invalidResponse,
        'Refresh removed the account session.',
        diagnosticCode: 'refresh_missing_refresh_cookie',
      );
    }
    return StoredAccountSession(
      cookieHeader: refreshedCookie,
      accessToken: accessToken,
    );
  }

  @override
  Future<void> logout(StoredAccountSession session) async {
    await _post(
      'auth/logout',
      cookieHeader: session.cookieHeader,
      accessToken: session.accessToken,
      operation: _AuthOperation.logout,
    );
  }

  void close() {
    if (_ownsClient) _client.close(force: true);
  }

  Future<_AuthResponse> _post(
    String relativePath, {
    Map<String, Object?>? json,
    Map<String, String>? query,
    String? cookieHeader,
    String? accessToken,
    required _AuthOperation operation,
  }) async {
    final resolved = baseUri.resolve(relativePath);
    final uri = query == null
        ? resolved
        : resolved.replace(queryParameters: query);
    try {
      if (!isAllowedNoveliaRequestUri(uri)) {
        throw const NoveliaAuthException(
          NoveliaAuthFailureKind.invalidResponse,
          'The authentication host is not allowed.',
        );
      }
      final request = await _client.postUrl(uri).timeout(requestTimeout);
      pinNoveliaHttpRequest(request);
      request.headers.set(HttpHeaders.acceptHeader, 'text/plain, */*');
      if (cookieHeader != null && cookieHeader.trim().isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      }
      if (accessToken != null && accessToken.trim().isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
      }
      if (json != null) {
        // Novelia's auth service rejects the otherwise-valid
        // `application/json; charset=utf-8` emitted by ContentType.json.
        request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        request.add(utf8.encode(jsonEncode(json)));
      }
      final response = await request.close().timeout(requestTimeout);
      final body = <int>[];
      await for (final chunk in response.timeout(requestTimeout)) {
        if (body.length + chunk.length > maximumResponseBytes) {
          throw const NoveliaAuthException(
            NoveliaAuthFailureKind.invalidResponse,
            'Authentication response exceeded the configured size limit.',
            diagnosticCode: 'response_too_large',
          );
        }
        body.addAll(chunk);
      }
      final responseCookies = List<Cookie>.unmodifiable(response.cookies);
      assert(() {
        _debugTrace({
          'event': 'response',
          'operation': operation.name,
          'status': response.statusCode,
          'contentType': response.headers.contentType?.toString(),
          'cookieNames':
              responseCookies.map((cookie) => cookie.name).toSet().toList()
                ..sort(),
          'body': _describeBody(body),
        });
        return true;
      }());
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _statusFailure(response.statusCode, operation);
      }
      return _AuthResponse(body: body, cookies: responseCookies);
    } on NoveliaAuthException {
      rethrow;
    } on TimeoutException {
      throw const NoveliaAuthException(
        NoveliaAuthFailureKind.timeout,
        'Authentication request timed out.',
      );
    } on SocketException {
      throw const NoveliaAuthException(
        NoveliaAuthFailureKind.network,
        'Authentication service could not be reached.',
      );
    } on TlsException {
      throw const NoveliaAuthException(
        NoveliaAuthFailureKind.network,
        'The secure authentication connection failed.',
      );
    } on HttpException {
      throw const NoveliaAuthException(
        NoveliaAuthFailureKind.network,
        'Authentication request failed.',
      );
    }
  }

  static NoveliaAuthException _statusFailure(
    int statusCode,
    _AuthOperation operation,
  ) {
    if (operation == _AuthOperation.login &&
        (statusCode == 400 || statusCode == 401 || statusCode == 403)) {
      return NoveliaAuthException(
        NoveliaAuthFailureKind.invalidCredentials,
        'The username or password was rejected.',
        statusCode: statusCode,
      );
    }
    if (operation != _AuthOperation.login &&
        (statusCode == 401 || statusCode == 403)) {
      return NoveliaAuthException(
        NoveliaAuthFailureKind.sessionExpired,
        'The account session has expired.',
        statusCode: statusCode,
      );
    }
    if (statusCode >= 500) {
      return NoveliaAuthException(
        NoveliaAuthFailureKind.server,
        'The authentication service returned a server error.',
        statusCode: statusCode,
      );
    }
    return NoveliaAuthException(
      NoveliaAuthFailureKind.invalidResponse,
      'The authentication service returned an unexpected status.',
      statusCode: statusCode,
    );
  }

  static String _mergeCookies(String existingHeader, List<Cookie> updates) {
    final cookies = <String, String>{};
    for (final part in existingHeader.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final name = part.substring(0, separator).trim();
      final value = part.substring(separator + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) cookies[name] = value;
    }
    final now = DateTime.now().toUtc();
    for (final cookie in updates) {
      final expired =
          cookie.maxAge == 0 ||
          (cookie.expires != null && !cookie.expires!.toUtc().isAfter(now));
      if (expired || cookie.value.isEmpty) {
        cookies.remove(cookie.name);
      } else {
        cookies[cookie.name] = cookie.value;
      }
    }
    return cookies.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  void _debugTrace(Map<String, Object?> fields) {
    final message = jsonEncode(fields);
    if (debugDiagnosticSink case final sink?) {
      sink(message);
    } else {
      developer.log(message, name: 'novelia.auth');
      stderr.writeln('novelia.auth $message');
    }
  }

  static Map<String, Object?> _describeBody(List<int> body) {
    final text = utf8.decode(body, allowMalformed: true).trim();
    final description = <String, Object?>{
      'bytes': body.length,
      'characters': text.length,
    };
    if (text.isEmpty) {
      description['kind'] = 'empty';
      return description;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      description['kind'] = 'text';
      description.addAll(_describePossibleToken(text));
      return description;
    }
    if (decoded is Map) {
      description['kind'] = 'json_object';
      description['fields'] = _fieldTypes(decoded);
      return description;
    }
    if (decoded is List) {
      description['kind'] = 'json_array';
      description['items'] = decoded.length;
      description['itemTypes'] = decoded.map(_valueType).toSet().toList()
        ..sort();
      return description;
    }
    if (decoded is String) {
      description['kind'] = 'json_string';
      description['decodedCharacters'] = decoded.length;
      description.addAll(_describePossibleToken(decoded.trim()));
      return description;
    }
    description['kind'] = 'json_${_valueType(decoded)}';
    return description;
  }

  static Map<String, Object?> _describePossibleToken(String value) {
    final segments = value.split('.');
    final description = <String, Object?>{'tokenSegments': segments.length};
    if (segments.length != 3 || segments.any((segment) => segment.isEmpty)) {
      return description;
    }
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))),
      );
      description['jwtPayloadType'] = _valueType(payload);
      if (payload is Map) description['jwtClaims'] = _fieldTypes(payload);
    } on Object {
      description['jwtPayloadType'] = 'malformed';
    }
    return description;
  }

  static Map<String, String> _fieldTypes(Map<Object?, Object?> value) {
    final fields = <String, String>{};
    for (final entry in value.entries) {
      fields[entry.key.toString()] = _valueType(entry.value);
    }
    return Map.fromEntries(
      fields.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key)),
    );
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
}

enum _AuthOperation { login, refresh, logout }

class _AuthResponse {
  const _AuthResponse({required this.body, required this.cookies});

  final List<int> body;
  final List<Cookie> cookies;
}
