import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/platform/app_version.dart';

void main() {
  const channel = MethodChannel('io.github.troyt666.jfzreader/app_version');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('installed version combines platform name and build number', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'get');
      return {'name': '1.2.3', 'buildNumber': '45'};
    });

    final version = await const InstalledAppVersion().load();

    expect(version.name, '1.2.3');
    expect(version.buildNumber, '45');
    expect(version.display, '1.2.3+45');
  });

  test('missing platform metadata never shows a stale version', () async {
    final version = await const InstalledAppVersion().load();

    expect(version.display, '版本未知');
  });
}
