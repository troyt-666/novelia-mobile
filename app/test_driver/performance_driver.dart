import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) => writeResponseData(
    data,
    destinationDirectory:
        Platform.environment['PROFILE_OUTPUT_DIRECTORY'] ??
        'build/android-profile',
    testOutputFilename: Platform.environment['PROFILE_OUTPUT_NAME'] ?? 'frames',
  ),
);
