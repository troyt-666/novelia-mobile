import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test('product metadata and native update wiring are configured', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pubspec)?.group(1),
      'jfzreader',
    );
    expect(
      pubspec,
      contains(RegExp(r'^version: \d+\.\d+\.\d+\+\d+$', multiLine: true)),
    );

    final macInfo = File('macos/Runner/Info.plist').readAsStringSync();
    expect(_plistValues(macInfo)['CFBundleDisplayName'], 'JFZ Reader');

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
    final packageVersion = RegExp(
      r'version = ([0-9.]+);',
    ).firstMatch(macProject)!.group(1);
    final workflow = File(
      '../.github/workflows/publish-release-artifacts.yml',
    ).readAsStringSync();
    final tools = RegExp(
      r'Sparkle/releases/download/([0-9.]+)/Sparkle-([0-9.]+)\.tar\.xz',
    ).firstMatch(workflow)!;
    expect(tools.group(1), packageVersion);
    expect(tools.group(2), packageVersion);
    final macUpdateInfo = File('macos/Runner/Info.plist').readAsStringSync();
    final updateInfo = _plistValues(macUpdateInfo);
    expect(updateInfo['SUEnableInstallerLauncherService'], 'true');
    expect(updateInfo['SUVerifyUpdateBeforeExtraction'], 'true');
    expect(Uri.parse(updateInfo['SUFeedURL']!).path, endsWith('/appcast.xml'));
    expect(
      updateInfo['SUPublicEDKey'],
      matches(RegExp(r'^[A-Za-z0-9+/]{43}=$')),
    );
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

    final workflow = File(
      '../.github/workflows/publish-release-artifacts.yml',
    ).readAsStringSync();
    expect(workflow, contains('JFZREADER_ANDROID_STORE_BASE64'));
    expect(workflow, contains('JFZREADER_ANDROID_STORE_PASSWORD'));
    expect(workflow, contains('JFZREADER_ANDROID_KEY_ALIAS'));
    expect(workflow, contains('JFZREADER_ANDROID_KEY_PASSWORD'));
    expect(workflow, contains('verify_android_release.sh'));
    expect(workflow, contains('generate-update-site.sh'));
    expect(workflow, contains('SPARKLE_PRIVATE_KEY'));
    expect(workflow, contains('macos.sparkle-signature'));
    // The tool version can change; archive integrity checking must remain wired.
    expect(workflow, matches(RegExp(r"'[a-f0-9]{64}'")));
    expect(workflow, contains('shasum -a 256 -c -'));
    expect(workflow, contains('actions/deploy-pages@v4'));
    expect(workflow, contains('pages: write'));
    expect(workflow, isNot(contains('signingConfigs.getByName("debug")')));
  });

  test('native implementations declare the installed-version channel', () {
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

  test('macOS account storage uses preferences rather than Keychain APIs', () {
    final runner = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();
    expect(runner, contains('UserDefaults.standard'));
    expect(runner, isNot(contains('SecItemCopyMatching')));
    expect(runner, isNot(contains('kSecClassGenericPassword')));
  });

  test('Apple signing materials stay untracked', () {
    const ignored = [
      'app/test-signing.p12',
      'app/test-signing.cer',
      'app/test-signing.mobileprovision',
      'app/test-signing.p8',
      'app/ios/ExportOptions.test.plist',
    ];
    final ignoreResult = Process.runSync('git', [
      'check-ignore',
      '--no-index',
      ...ignored,
    ], workingDirectory: '..');
    expect(ignoreResult.exitCode, 0);
    expect(ignoreResult.stdout.toString().trim().split('\n'), ignored);

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

Map<String, String> _plistValues(String source) {
  final elements = XmlDocument.parse(
    source,
  ).rootElement.getElement('dict')!.childElements.toList();
  return {
    for (var index = 0; index < elements.length; index += 2)
      elements[index].innerText: elements[index + 1].name.local == 'string'
          ? elements[index + 1].innerText
          : elements[index + 1].name.local,
  };
}
