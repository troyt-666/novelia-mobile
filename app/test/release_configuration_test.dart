import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v1 product metadata is release-ready', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, startsWith('name: jfzreader\n'));
    expect(pubspec, contains('version: 1.0.0+1'));
    expect(pubspec, isNot(contains('reader spike')));

    final macInfo = File('macos/Runner/Info.plist').readAsStringSync();
    expect(macInfo, contains('<key>CFBundleDisplayName</key>'));
    expect(macInfo, contains('<string>JFZ Reader</string>'));

    final android = File('android/app/build.gradle.kts').readAsStringSync();
    expect(android, contains('applicationId = "io.github.troyt666.jfzreader"'));

    final ios = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(
      ios,
      contains('PRODUCT_BUNDLE_IDENTIFIER = io.github.troyt666.jfzreader;'),
    );
    expect(ios, isNot(contains('PRODUCT_BUNDLE_IDENTIFIER = dev.novelia')));
  });

  test('Android release never falls back to the shared debug certificate', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('JFZREADER_ANDROID_STORE_FILE'));
    expect(gradle, contains('JFZREADER_ANDROID_STORE_PASSWORD'));
    expect(gradle, contains('JFZREADER_ANDROID_KEY_ALIAS'));
    expect(gradle, contains('JFZREADER_ANDROID_KEY_PASSWORD'));
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
