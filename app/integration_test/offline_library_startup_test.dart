import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/offline_library_startup_test.dart' as startup;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final screenshots = <String, String>{};
  startup.runOfflineLibraryStartupTests(
    useDeviceViewport: true,
    capture: (tester, name) async {
      debugPrint('Offline fixture: capture $name');
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        screenshots[name] = base64Encode(data!.buffer.asUint8List());
        binding.reportData = {'screenshots': screenshots};
        image.dispose();
      });
      debugPrint('Offline fixture: captured $name');
    },
  );
}
