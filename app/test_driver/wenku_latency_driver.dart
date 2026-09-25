import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) => writeResponseData(
    data,
    destinationDirectory: 'build/macos-reading-profile',
    testOutputFilename: 'epub-latency',
  ),
);
