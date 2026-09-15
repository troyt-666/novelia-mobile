import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/reader_horizontal_layout_test.dart' as layout;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  layout.runHorizontalLayoutTests(
    useDeviceViewport: true,
    onSamplePage: (tester, scale) async {
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reader-stream'))),
      );
      await tester.pumpAndSettle();
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pumpAndSettle();
      }
      await binding.takeScreenshot('horizontal-page-scale-$scale');
    },
  );
}
