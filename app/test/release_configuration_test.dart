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

    final workflow = File(
      '../.github/workflows/publish-release-artifacts.yml',
    ).readAsStringSync();
    expect(workflow, contains('JFZREADER_ANDROID_STORE_BASE64'));
    expect(workflow, contains('JFZREADER_ANDROID_STORE_PASSWORD'));
    expect(workflow, contains('JFZREADER_ANDROID_KEY_ALIAS'));
    expect(workflow, contains('JFZREADER_ANDROID_KEY_PASSWORD'));
    expect(workflow, contains('verify_android_release.sh'));
    expect(workflow, contains('build ios --release --no-codesign'));
    expect(workflow, contains(r'JFZ-Reader-${tag}-ios-unsigned.ipa'));
    expect(workflow, isNot(contains('signingConfigs.getByName("debug")')));
  });

  test('macOS account storage does not trigger Keychain authorization', () {
    final runner = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();
    expect(runner, contains('UserDefaults.standard'));
    expect(runner, isNot(contains('SecItemCopyMatching')));
    expect(runner, isNot(contains('kSecClassGenericPassword')));
  });

  test('Apple signing materials stay untracked', () {
    final gitignore = File('../.gitignore').readAsStringSync();
    expect(gitignore, contains('*.p12'));
    expect(gitignore, contains('*.cer'));
    expect(gitignore, contains('*.mobileprovision'));
    expect(gitignore, contains('*.p8'));
    expect(gitignore, contains('ExportOptions*.plist'));

    final example = File(
      'ios/Flutter/Local.xcconfig.example',
    ).readAsStringSync();
    expect(example, contains('NOVELIA_DEVELOPMENT_TEAM='));
    expect(
      example,
      isNot(contains(RegExp(r'NOVELIA_DEVELOPMENT_TEAM=[A-Z0-9]{10}'))),
    );

    final listed = Process.runSync('git', ['ls-files'], workingDirectory: '..');
    expect(listed.exitCode, 0);
    final files = listed.stdout.toString().split('\n');
    bool isSigningArtifact(String path) {
      final name = path.split('/').last;
      return name.endsWith('.p12') ||
          name.endsWith('.cer') ||
          name.endsWith('.mobileprovision') ||
          name.endsWith('.p8') ||
          (name.startsWith('ExportOptions') &&
              name.endsWith('.plist') &&
              !name.endsWith('.plist.example'));
    }

    expect(files.where(isSigningArtifact), isEmpty);
    expect(files, contains('app/ios/ExportOptions.ad-hoc.plist.example'));
    expect(files, isNot(contains('app/ios/Flutter/Local.xcconfig')));
    expect(files, isNot(contains('docs/private-release-guide.md')));
    expect(File('../docs/release-guide.md').existsSync(), isTrue);
    expect(File('ios/Flutter/Local.xcconfig.example').existsSync(), isTrue);
  });
}
