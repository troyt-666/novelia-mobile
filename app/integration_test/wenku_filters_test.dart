import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jfzreader/features/wenku/wenku_catalog_screen.dart';
import 'package:jfzreader/gateway/novelia/http_novelia_wenku_gateway.dart';

/// Native UI plus real HTTP gateway; all sessions and content are synthetic.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Keep native accessibility enabled before the test records its handles.
  // Inspecting or foregrounding the macOS window must not change that baseline.
  setUpAll(() => binding.platformDispatcher.semanticsEnabledTestValue = true);
  tearDownAll(binding.platformDispatcher.clearSemanticsEnabledTestValue);
  testWidgets(
    'Wenku R18 filters retain authentication across native journeys',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <({Uri uri, String? authorization})>[];
      final subscription = server.listen((request) async {
        final authorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        requests.add((uri: request.uri, authorization: authorization));
        final query = request.uri.queryParameters;
        final level = query['level'];
        final restricted =
            level == '5' ||
            level == '6' ||
            request.uri.path.contains('/wenku/');
        request.response.headers.contentType = ContentType.json;
        if (restricted && authorization != 'Bearer fixture-current') {
          request.response.statusCode = HttpStatus.unauthorized;
        } else if (request.uri.path == '/api/comment') {
          request.response.write('{"items":[],"pageNumber":0}');
        } else if (request.uri.path.contains('/wenku/')) {
          request.response.write(
            jsonEncode({
              'title': '架空の物語',
              'titleZh': '虚构作品详情',
              'cover': null,
              'authors': ['虚构作者'],
              'artists': [],
              'keywords': [],
              'level': 'R18女性向',
              'introduction': '用于验证登录状态的虚构作品。',
              'volumes': [],
              'volumeJp': [],
              'volumeZh': [],
            }),
          );
        } else {
          final page = int.parse(query['page'] ?? '0');
          final title = switch (level) {
            '5' => '男性向筛选 · 虚构作品 ${page + 1}',
            '6' => '女性向筛选 · 虚构作品 ${page + 1}',
            _ => '一般向 · 虚构作品',
          };
          request.response.write(
            jsonEncode({
              'items': [
                {
                  'id': 'fixture-$level-$page',
                  'title': '架空の物語',
                  'titleZh': title,
                  'cover': null,
                },
              ],
              'pageNumber': 2,
            }),
          );
        }
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      String? token;
      var refreshCount = 0;
      final gateway = HttpNoveliaWenkuGateway(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
        accessTokenProvider: ({bool forceRefresh = false}) {
          if (forceRefresh) {
            refreshCount++;
            token = 'fixture-current';
          }
          return token;
        },
      );
      addTearDown(gateway.close);
      final captureKey = GlobalKey();
      final screenshots = <String, String>{};
      binding.reportData = {'screenshots': screenshots};

      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        screenshots[name] = base64Encode(data!.buffer.asUint8List());
        image.dispose();
      }

      Future<void> tap(String key) async {
        final finder = find.byKey(ValueKey(key));
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF397B62),
              ),
              fontFamilyFallback: const [
                'PingFang SC',
                'Noto Sans CJK SC',
                'Hiragino Sans',
              ],
            ),
            home: WenkuCatalogScreen(gateway: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('一般向 · 虚构作品'), findsOneWidget);
      await tap('wenku-level-r18Male');
      expect(find.text('请在设置中登录，并确认账号满足站点的访问条件。'), findsOneWidget);
      expect(refreshCount, 0);
      await capture('wenku-r18-macos-login-required');

      token = 'fixture-expired';
      await tap('wenku-retry-button');
      expect(find.text('男性向筛选 · 虚构作品 1'), findsOneWidget);
      expect(refreshCount, 1);
      await tap('wenku-load-more-button');
      expect(find.text('男性向筛选 · 虚构作品 2'), findsOneWidget);
      await capture('wenku-r18-macos-male');

      await tap('wenku-level-r18Female');
      expect(find.text('女性向筛选 · 虚构作品 1'), findsOneWidget);
      expect(find.text('男性向筛选 · 虚构作品 1'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('wenku-search-field')),
        '虚构',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tap('wenku-load-more-button');
      expect(find.text('女性向筛选 · 虚构作品 2'), findsOneWidget);
      await capture('wenku-r18-macos-female');

      await tester.tap(find.text('女性向筛选 · 虚构作品 1'));
      await tester.pumpAndSettle();
      expect(find.text('虚构作品详情'), findsWidgets);
      expect(
        requests
            .where((request) => request.uri.path.contains('/wenku/'))
            .single
            .authorization,
        'Bearer fixture-current',
      );
      final pages = requests
          .where((request) => request.uri.queryParameters['page'] == '1')
          .toList();
      expect(pages.map((request) => request.uri.queryParameters['level']), [
        '5',
        '6',
      ]);
      expect(
        pages.map((request) => request.authorization),
        everyElement('Bearer fixture-current'),
      );
      expect(pages.last.uri.queryParameters['query'], '虚构');
      expect(refreshCount, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
