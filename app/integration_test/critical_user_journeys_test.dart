import 'package:integration_test/integration_test.dart';

import '../test/critical_user_journeys_test.dart' as journeys;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  journeys.runCriticalUserJourneys(useDeviceViewport: true);
}
