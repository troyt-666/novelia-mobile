import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jfzreader/core/database/app_database.dart';
import 'package:jfzreader/core/platform/app_version.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Harmony native storage, SQLite persistence and WebView',
    (tester) async {
      final version = await const InstalledAppVersion().load();
      expect(version.name, isNotEmpty);
      final support = await getApplicationSupportDirectory();
      final temporary = await support.createTemp('harmony-smoke-');
      try {
        final path = '${temporary.path}/fixture.sqlite3';
        final database = NoveliaDatabase.openFile(path);
        expect(database.userVersion, NoveliaDatabase.currentSchemaVersion);
        database.execute('CREATE TABLE smoke (value TEXT NOT NULL)');
        database.execute('INSERT INTO smoke VALUES (?)', ['鸿蒙离线阅读']);
        database.close();
        final reopened = NoveliaDatabase.openFile(path);
        try {
          expect(
            reopened.select('SELECT value FROM smoke').single['value'],
            '鸿蒙离线阅读',
          );
        } finally {
          reopened.close();
        }
      } finally {
        await temporary.delete(recursive: true);
      }

      const sessions = MethodChannel(
        'io.github.troyt666.jfzreader/account_session',
      );
      final existing = await sessions.invokeMethod<String>('read');
      // Never replace an account already saved on the test phone.
      if (existing == null) {
        final fixture = 'fixture-cookie-token-${'x' * 4096}';
        try {
          await sessions.invokeMethod<void>('write', fixture);
          expect(await sessions.invokeMethod<String>('read'), fixture);
          await sessions.invokeMethod<void>('write', '$fixture-updated');
          expect(
            await sessions.invokeMethod<String>('read'),
            '$fixture-updated',
          );
        } finally {
          await sessions.invokeMethod<void>('clear');
        }
        expect(await sessions.invokeMethod<String>('read'), isNull);
      }

      final loaded = Completer<void>();
      final webview = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (!loaded.isCompleted) loaded.complete();
            },
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WebViewWidget(controller: webview)),
        ),
      );
      await webview.loadHtmlString('<html><body>harmony-fixture</body></html>');
      await loaded.future.timeout(const Duration(seconds: 30));
      expect(
        await webview.runJavaScriptReturningResult('document.body.innerText'),
        contains('harmony-fixture'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: Platform.operatingSystem != 'ohos',
  );
}
