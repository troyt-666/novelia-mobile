import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v1 product metadata is release-ready', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, startsWith('name: jfzreader\n'));
    expect(
      pubspec,
      contains(RegExp(r'^version: \d+\.\d+\.\d+\+\d+$', multiLine: true)),
    );
    expect(pubspec, isNot(contains('reader spike')));

    final macInfo = File('macos/Runner/Info.plist').readAsStringSync();
    expect(macInfo, contains('<key>CFBundleDisplayName</key>'));
    expect(macInfo, contains('<string>JFZ Reader</string>'));

    final android = File('android/app/build.gradle.kts').readAsStringSync();
    expect(android, contains('applicationId = "io.github.troyt666.jfzreader"'));
    final androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(androidManifest, contains('REQUEST_INSTALL_PACKAGES'));
    expect(androidManifest, contains('FileProvider'));
    expect(androidManifest, contains('@xml/update_file_paths'));
    final androidActivity = File(
      'android/app/src/main/kotlin/io/github/troyt666/jfzreader/MainActivity.kt',
    ).readAsStringSync();
    expect(
      androidActivity,
      contains('io.github.troyt666.jfzreader/app_update_installer'),
    );
    expect(androidActivity, contains('canRequestPackageInstalls'));

    final macProject = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(macProject, contains('sparkle-project/Sparkle'));
    expect(macProject, contains('version = 2.9.2'));
    final macUpdateInfo = File('macos/Runner/Info.plist').readAsStringSync();
    expect(macUpdateInfo, contains('SUEnableInstallerLauncherService'));
    expect(macUpdateInfo, contains('SUVerifyUpdateBeforeExtraction'));
    expect(macUpdateInfo, contains('appcast.xml'));
    expect(macUpdateInfo, isNot(contains('SPARKLE_PUBLIC_KEY_PENDING')));
    final macRunner = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();
    expect(macRunner, contains('SPUStandardUpdaterController'));
    expect(macRunner, contains('checkForUpdates'));

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
    expect(workflow, contains(r'Release tag $RELEASE_TAG does not match'));
    expect(workflow, contains('build ios --release --no-codesign'));
    expect(workflow, contains(r'JFZ-Reader-${tag}-ios-unsigned.ipa'));
    expect(workflow, contains('Print :CFBundleIdentifier'));
    expect(workflow, contains('Print :MinimumOSVersion'));
    expect(workflow, contains('UsageDescription'));
    expect(workflow, contains('generate-update-site.sh'));
    expect(workflow, contains('SPARKLE_PRIVATE_KEY'));
    expect(workflow, contains('macos.sparkle-signature'));
    expect(
      workflow,
      contains('app/build/macos/Build/Products/Release/jfzreader.app'),
    );
    expect(
      workflow,
      isNot(
        contains(
          "find app/build/macos/Build/Products/Release -type d -name '*.app'",
        ),
      ),
    );
    expect(workflow, contains('Sparkle-2.9.2.tar.xz'));
    expect(
      workflow,
      contains(
        '1cb340cbbef04c6c0d162078610c25e2221031d794a3449d89f2f56f4df77c95',
      ),
    );
    expect(workflow, contains('actions/deploy-pages@v4'));
    expect(workflow, contains('pages: write'));
    expect(workflow, isNot(contains('signingConfigs.getByName("debug")')));

    final feedGenerator = File(
      '../.github/scripts/generate-update-site.sh',
    ).readAsStringSync();
    expect(feedGenerator, contains('altstore-source.json'));
    expect(feedGenerator, contains('latest.json'));
    expect(feedGenerator, contains('appcast.xml'));
    expect(feedGenerator, contains('sparkle:edSignature'));
    expect(feedGenerator, contains('sha256'));
    expect(feedGenerator, contains('io.github.troyt666.jfzreader'));
    expect(feedGenerator, contains('minOSVersion: "13.0"'));
  });

  test('supported platforms expose installed app version metadata', () {
    const channel = 'io.github.troyt666.jfzreader/app_version';
    for (final path in [
      'android/app/src/main/kotlin/io/github/troyt666/jfzreader/MainActivity.kt',
      'ios/Runner/AppDelegate.swift',
      'macos/Runner/MainFlutterWindow.swift',
    ]) {
      final implementation = File(path).readAsStringSync();
      expect(implementation, contains(channel), reason: path);
      expect(implementation, contains('buildNumber'), reason: path);
    }
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
