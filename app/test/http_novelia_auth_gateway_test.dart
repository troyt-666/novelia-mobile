import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelia_reader/core/account/account_models.dart';
import 'package:novelia_reader/gateway/novelia/http_novelia_auth_gateway.dart';
import 'package:novelia_reader/gateway/novelia/novelia_auth_gateway.dart';

void main() {
  test('HTTP auth gateway carries and rotates only response cookies', () async {
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serving = server.listen((request) async {
      requests.add(request.uri.path);
      if (request.uri.path.endsWith('/auth/login')) {
        expect(
          request.headers.value(HttpHeaders.contentTypeHeader),
          'application/json',
        );
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['app'], 'n');
        expect(body['username'], 'alice');
        expect(body['password'], 'secret');
        request.response.cookies.add(
          Cookie('refresh', 'first')
            ..httpOnly = true
            ..secure = true,
        );
        request.response.write('ok');
      } else if (request.uri.path.endsWith('/auth/refresh')) {
        expect(request.cookies.single.name, 'refresh');
        request.response.cookies.add(
          Cookie('refresh', 'rotated')
            ..httpOnly = true
            ..secure = true,
        );
        request.response.write(
          _token('alice', expiresIn: const Duration(hours: 1)),
        );
      } else if (request.uri.path.endsWith('/auth/logout')) {
        expect(request.cookies.single.value, 'rotated');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          startsWith('Bearer '),
        );
        request.response.write('ok');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    addTearDown(serving.cancel);
    final gateway = HttpNoveliaAuthGateway(
      baseUri: Uri.parse(
        'http://${server.address.address}:${server.port}/api/v1/',
      ),
    );
    addTearDown(gateway.close);

    final session = await gateway.login(
      username: ' alice ',
      password: 'secret',
    );
    expect(session.cookieHeader, 'refresh=rotated');
    expect(decodeNoveliaAccessToken(session.accessToken).username, 'alice');
    await gateway.logout(session);
    expect(requests, [
      '/api/v1/auth/login',
      '/api/v1/auth/refresh',
      '/api/v1/auth/logout',
    ]);
  });

  test(
    'debug trace describes invalid refresh without exposing secrets',
    () async {
      final trace = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final serving = server.listen((request) async {
        if (request.uri.path.endsWith('/auth/login')) {
          await utf8.decoder.bind(request).join();
          request.response.cookies.add(Cookie('refresh', 'secret-cookie'));
          request.response.write('ok');
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'accessToken': 'secret-token'}));
        }
        await request.response.close();
      });
      addTearDown(serving.cancel);
      final gateway = HttpNoveliaAuthGateway(
        baseUri: Uri.parse(
          'http://${server.address.address}:${server.port}/api/v1/',
        ),
        debugDiagnosticSink: trace.add,
      );
      addTearDown(gateway.close);

      await expectLater(
        gateway.login(username: 'alice', password: 'secret-password'),
        throwsA(
          isA<NoveliaAuthException>()
              .having(
                (error) => error.kind,
                'kind',
                NoveliaAuthFailureKind.invalidResponse,
              )
              .having(
                (error) => error.diagnosticCode,
                'diagnostic code',
                'refresh_invalid_access_token',
              ),
        ),
      );

      final combined = trace.join('\n');
      expect(combined, contains('"operation":"login"'));
      expect(combined, contains('"operation":"refresh"'));
      expect(combined, contains('"kind":"json_object"'));
      expect(combined, contains('"accessToken":"string"'));
      expect(combined, contains('"cookieNames":["refresh"]'));
      expect(combined, isNot(contains('secret-cookie')));
      expect(combined, isNot(contains('secret-token')));
      expect(combined, isNot(contains('secret-password')));
    },
  );
}

String _token(String username, {required Duration expiresIn}) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'none', 'typ': 'JWT'})}.'
      '${segment({'sub': username, 'role': 'member', 'iat': now, 'crat': now - 3600, 'exp': now + expiresIn.inSeconds})}.signature';
}
