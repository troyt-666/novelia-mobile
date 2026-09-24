import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    for (final entry
        in (data?['screenshots'] as Map<String, dynamic>? ?? {}).entries) {
      final file = File('build/ui-ux/2026-09-25/${entry.key}.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode(entry.value as String));
    }
  },
  writeResponseOnFailure: true,
);
