import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/offline_illustration_reader_test.dart' as reader;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  reader.runOfflineIllustrationReaderTest(
    useDeviceViewport: true,
    capture: (tester) async {
      await tester.runAsync(() async {
        final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        binding.reportData = {
          'screenshots': {
            'offline-illustrations': base64Encode(bytes!.buffer.asUint8List()),
          },
        };
        image.dispose();
      });
    },
  );
}
