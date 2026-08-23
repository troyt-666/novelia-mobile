import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/platform/app_update.dart';
import 'package:jfzreader/core/platform/app_version.dart';

void main() {
  const installed = AppVersion(name: '1.2.3', buildNumber: '4');

  test('semantic version and build number comparisons are monotonic', () {
    expect(
      isVersionNewer(
        candidate: const AppVersion(name: '1.3.0', buildNumber: '1'),
        installed: installed,
      ),
      isTrue,
    );
    expect(
      isVersionNewer(
        candidate: const AppVersion(name: '1.2.3', buildNumber: '5'),
        installed: installed,
      ),
      isTrue,
    );
    expect(
      isVersionNewer(
        candidate: const AppVersion(name: '1.2.3', buildNumber: '4'),
        installed: installed,
      ),
      isFalse,
    );
    expect(
      isVersionNewer(
        candidate: const AppVersion(name: '1.2.2', buildNumber: '99'),
        installed: installed,
      ),
      isFalse,
    );
  });

  test(
    'GitHub checker selects the platform artifact from a valid feed',
    () async {
      final requestedUris = <Uri>[];
      final checker = GitHubAppUpdateChecker(
        platform: AppUpdatePlatform.ios,
        manifestUri: Uri.parse('https://updates.example/latest.json'),
        manifestLoader: (uri) async {
          requestedUris.add(uri);
          return jsonEncode(_manifest(version: '1.2.4', buildNumber: 5));
        },
      );

      final result = await checker.check(installed);

      expect(requestedUris, [Uri.parse('https://updates.example/latest.json')]);
      expect(result.updateAvailable, isTrue);
      expect(result.latestVersion.display, '1.2.4+5');
      expect(result.platform, AppUpdatePlatform.ios);
      expect(result.downloadUri.path, endsWith('.ipa'));
      expect(result.artifact.size, 1024);
      expect(result.artifact.sha256, _checksum('b'));
      expect(result.altStoreSourceUri.path, endsWith('altstore-source.json'));
    },
  );

  test('update feeds and all distributed artifacts must use HTTPS', () async {
    final checker = GitHubAppUpdateChecker(
      platform: AppUpdatePlatform.android,
      manifestUri: Uri.parse('http://updates.example/latest.json'),
      manifestLoader: (_) async => jsonEncode(_manifest()),
    );
    await expectLater(checker.check(installed), throwsFormatException);

    final manifest = _manifest();
    final downloads = manifest['downloads']! as Map<String, Object?>;
    downloads['android'] = <String, Object?>{
      'url': 'http://downloads.example/jfz-reader.apk',
      'size': 1024,
      'sha256': _checksum('a'),
    };
    expect(() => AppUpdateManifest.fromJson(manifest), throwsFormatException);

    final redirected = _manifest()
      ..['releasePageUrl'] = 'https://downloads.example/release';
    expect(() => AppUpdateManifest.fromJson(redirected), throwsFormatException);
  });

  test('unknown manifest schemas fail closed', () {
    final manifest = _manifest()..['schemaVersion'] = 2;
    expect(() => AppUpdateManifest.fromJson(manifest), throwsFormatException);
  });
}

Map<String, Object?> _manifest({
  String version = '1.2.3',
  int buildNumber = 4,
}) {
  return <String, Object?>{
    'schemaVersion': 1,
    'version': version,
    'buildNumber': buildNumber,
    'releasePageUrl':
        'https://github.com/troyt-666/novelia-mobile/releases/tag/v$version',
    'altStoreSourceUrl': defaultAltStoreSourceUri,
    'releaseNotes': 'Bug fixes.',
    'downloads': <String, Object?>{
      'android': <String, Object?>{
        'url':
            'https://github.com/troyt-666/novelia-mobile/releases/download/'
            'v$version/jfz-reader.apk',
        'size': 1024,
        'sha256': _checksum('a'),
      },
      'ios': <String, Object?>{
        'url':
            'https://github.com/troyt-666/novelia-mobile/releases/download/'
            'v$version/jfz-reader.ipa',
        'size': 1024,
        'sha256': _checksum('b'),
      },
      'macos': <String, Object?>{
        'url':
            'https://github.com/troyt-666/novelia-mobile/releases/download/'
            'v$version/jfz-reader.dmg',
        'size': 1024,
        'sha256': _checksum('c'),
      },
    },
  };
}

String _checksum(String character) => List.filled(64, character).join();
