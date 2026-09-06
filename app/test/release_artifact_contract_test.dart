import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:jfzreader/core/platform/app_update.dart';

void main() {
  test(
    'generated feeds are usable by the updater and preserve signed artifact metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('release-feed-');
      addTearDown(() => root.delete(recursive: true));
      final environment = <String, String>{
        'RELEASE_TAG': 'v1.2.3+45',
        'APP_VERSION': '1.2.3',
        'APP_BUILD_NUMBER': '45',
        'RELEASE_PUBLISHED_AT': '2026-09-06T12:00:00Z',
        'RELEASE_PAGE_URL':
            'https://github.com/troyt-666/novelia-mobile/releases/tag/v1.2.3+45',
        'GITHUB_REPOSITORY': 'troyt-666/novelia-mobile',
        'GITHUB_REPOSITORY_OWNER': 'troyt-666',
        'SITE_OUTPUT_DIR': '${root.path}/site',
        'RELEASE_NOTES_FILE': '${root.path}/notes',
        'MACOS_SPARKLE_SIGNATURE_FILE': '${root.path}/signature',
      };
      final data = <AppUpdatePlatform, List<int>>{};
      for (final platform in AppUpdatePlatform.values) {
        final bytes = utf8.encode('fixture ${platform.name}');
        data[platform] = bytes;
        final path = '${root.path}/${platform.name}';
        await File(path).writeAsBytes(bytes);
        environment[switch (platform) {
              AppUpdatePlatform.android => 'ANDROID_APK',
              AppUpdatePlatform.ios => 'IOS_IPA',
              AppUpdatePlatform.macos => 'MACOS_DMG',
            }] =
            path;
      }
      const notes = '修复 <标签> & "引号"\n第二行';
      await File(environment['RELEASE_NOTES_FILE']!).writeAsString(notes);
      final signature = File(environment['MACOS_SPARKLE_SIGNATURE_FILE']!);
      await signature.writeAsString(
        'sparkle:edSignature="Zml4dHVyZQ==" length="${data[AppUpdatePlatform.macos]!.length}"',
      );
      Future<ProcessResult> generate([
        Map<String, String> overrides = const {},
      ]) => Process.run(
        'bash',
        ['.github/scripts/generate-update-site.sh'],
        workingDirectory: '..',
        environment: {...environment, ...overrides},
      );
      final result = await generate();
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final site = environment['SITE_OUTPUT_DIR']!;
      final manifest = AppUpdateManifest.fromJson(
        jsonDecode(await File('$site/latest.json').readAsString())
            as Map<String, dynamic>,
      );
      expect(manifest.version.display, '1.2.3+45');
      expect(manifest.releaseNotes, notes);
      for (final platform in AppUpdatePlatform.values) {
        final artifact = manifest.artifactFor(platform);
        expect(artifact.size, data[platform]!.length);
        expect(artifact.sha256, sha256.convert(data[platform]!).toString());
        expect(artifact.uri.path, contains('/releases/download/v1.2.3+45/'));
      }
      final appcast = XmlDocument.parse(
        await File('$site/appcast.xml').readAsString(),
      );
      final enclosure = appcast.findAllElements('enclosure').single;
      expect(
        enclosure.getAttribute(
          'edSignature',
          namespace: 'http://www.andymatuschak.org/xml-namespaces/sparkle',
        ),
        'Zml4dHVyZQ==',
      );
      expect(
        int.parse(enclosure.getAttribute('length')!),
        data[AppUpdatePlatform.macos]!.length,
      );
      expect(
        enclosure.getAttribute('url'),
        manifest.artifactFor(AppUpdatePlatform.macos).uri.toString(),
      );
      expect(appcast.findAllElements('description').last.innerText, notes);
      final altstore =
          jsonDecode(await File('$site/altstore-source.json').readAsString())
              as Map;
      final app = (altstore['apps'] as List).single as Map;
      expect(app['bundleIdentifier'], 'io.github.troyt666.jfzreader');
      final version = (app['versions'] as List).single as Map;
      expect(
        version['downloadURL'],
        manifest.artifactFor(AppUpdatePlatform.ios).uri.toString(),
      );
      expect(
        version['sha256'],
        manifest.artifactFor(AppUpdatePlatform.ios).sha256,
      );
      expect(version['minOSVersion'], '13.0');
      expect((await generate({'RELEASE_TAG': 'v9.9.9+1'})).exitCode, isNot(0));
      expect(
        (await generate({'ANDROID_APK': '${root.path}/missing'})).exitCode,
        isNot(0),
      );
      await signature.writeAsString(
        'sparkle:edSignature="Zml4dHVyZQ==" length="9999"',
      );
      expect((await generate()).exitCode, isNot(0));
      await signature.delete();
      expect((await generate()).exitCode, isNot(0));
    },
  );

  test(
    'APK verifier rejects failed verification and debug certificates',
    () async {
      final root = await Directory.systemTemp.createTemp('apk-verifier-');
      addTearDown(() => root.delete(recursive: true));
      final apk = File('${root.path}/fixture.apk');
      await apk.writeAsString('fixture bytes');
      final signer = File('${root.path}/apksigner');
      await signer.writeAsString('''#!/bin/sh
[ "\$1" = verify ] && [ "\$2" = --verbose ] && [ "\$3" = --print-certs ] && [ -f "\$4" ] || exit 2
printf '%s\\n' "\$TEST_CERTIFICATE"
exit "\$TEST_VERIFY_EXIT"
''');
      await Process.run('chmod', ['+x', signer.path]);
      Future<ProcessResult> verify(String certificate, String status) =>
          Process.run(
            'bash',
            ['scripts/verify_android_release.sh', apk.path],
            environment: {
              'APKSIGNER': signer.path,
              'TEST_CERTIFICATE': certificate,
              'TEST_VERIFY_EXIT': status,
            },
          );
      expect(
        (await verify(
          'Signer certificate DN: CN=Release Fixture',
          '0',
        )).exitCode,
        0,
      );
      expect(
        (await verify('Signer certificate DN: CN=Android Debug', '0')).exitCode,
        isNot(0),
      );
      expect((await verify('verification failed', '1')).exitCode, isNot(0));
    },
  );
}
