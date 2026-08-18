import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android release never falls back to the shared debug certificate', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('NOVELIA_ANDROID_STORE_FILE'));
    expect(gradle, contains('NOVELIA_ANDROID_STORE_PASSWORD'));
    expect(gradle, contains('NOVELIA_ANDROID_KEY_ALIAS'));
    expect(gradle, contains('NOVELIA_ANDROID_KEY_PASSWORD'));
    expect(
      gradle,
      isNot(contains('signingConfig = signingConfigs.getByName("debug")')),
    );

    final verifier = File(
      'scripts/verify_android_release.sh',
    ).readAsStringSync();
    expect(verifier, contains('Android Debug'));
    expect(verifier, contains('apksigner verify'));
  });

  test('macOS account storage does not trigger Keychain authorization', () {
    final runner = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();
    expect(runner, contains('UserDefaults.standard'));
    expect(runner, isNot(contains('SecItemCopyMatching')));
    expect(runner, isNot(contains('kSecClassGenericPassword')));
  });
}
