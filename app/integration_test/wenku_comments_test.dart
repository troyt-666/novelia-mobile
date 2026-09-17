import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/wenku_details_screen_test.dart' as journeys;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var converted = false;
  journeys.runWenkuCommentJourneys(
    useDeviceViewport: true,
    capture: (name) async {
      if (!converted) {
        await binding.convertFlutterSurfaceToImage();
        converted = true;
        addTearDown(() => converted = false);
        await binding.pump();
      }
      await binding.takeScreenshot(name);
    },
  );
}
