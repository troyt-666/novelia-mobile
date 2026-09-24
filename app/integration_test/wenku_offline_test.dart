import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jfzreader/features/wenku/wenku_catalog_screen.dart';
import 'package:jfzreader/features/wenku/wenku_epub_store.dart';
import 'package:jfzreader/gateway/novelia/http_novelia_wenku_gateway.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../test/support/wenku_offline_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => binding.platformDispatcher.semanticsEnabledTestValue = true);
  tearDownAll(binding.platformDispatcher.clearSemanticsEnabledTestValue);

  testWidgets(
    'offline catalog opens new and legacy downloads in native WebView',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'wenku-native-offline-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = WenkuEpubStore(rootDirectory: () async => root);
      await store.save(
        const WenkuEpubRequest(
          novelId: 'fixture-novel',
          volumeId: '第一卷.epub',
          order: WenkuBilingualOrder.chineseFirst,
          providers: [WenkuTranslationProvider.sakura],
          filename: '第一卷.epub',
        ),
        wenkuOfflineEpub(),
        title: '下载的离线列车',
      );
      await File(
        '${root.path}/wenku/0123456789abcdef0123.epub',
      ).writeAsBytes(wenkuOfflineEpub(title: '旧版离线列车'));

      // No service is listening. Exercise an actual failed socket connection.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}/api/');
      await server.close(force: true);
      final gateway = HttpNoveliaWenkuGateway(baseUri: origin);
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

      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF397B62),
              ),
            ),
            home: WenkuCatalogScreen(
              gateway: gateway,
              // Recreate storage as on a cold app launch.
              store: WenkuEpubStore(rootDirectory: () async => root),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('wenku-retry-button')), findsOneWidget);
      await capture('wenku-offline-catalog');
      await tester.tap(find.byKey(const ValueKey('wenku-downloads-button')));
      await tester.pumpAndSettle();
      expect(find.text('下载的离线列车'), findsOneWidget);
      expect(find.text('旧版离线列车'), findsOneWidget);
      await capture('wenku-offline-downloads');

      for (final title in ['下载的离线列车', '旧版离线列车']) {
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        final controller = tester
            .widget<WebViewWidget>(find.byType(WebViewWidget))
            .platform
            .params
            .controller;
        String body = '';
        for (var attempt = 0; attempt < 50; attempt++) {
          body = (await controller.runJavaScriptReturningResult(
            'document.body.innerText',
          )).toString();
          if (body.contains('即使没有网络')) break;
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(body, contains('即使没有网络，下载的故事也应该继续。'));
        expect(body, contains('ネットがなくても、物語は続く。'));
        expect(
          await controller.runJavaScriptReturningResult(
            'document.querySelectorAll(".wenku-jp").length',
          ),
          1,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
