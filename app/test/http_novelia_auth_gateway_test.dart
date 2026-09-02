import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/account/account_models.dart';
import 'package:jfzreader/gateway/novelia/http_novelia_auth_gateway.dart';

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
}

String _token(String username, {required Duration expiresIn}) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'none', 'typ': 'JWT'})}.'
      '${segment({'sub': username, 'role': 'member', 'iat': now, 'crat': now - 3600, 'exp': now + expiresIn.inSeconds})}.signature';
}
