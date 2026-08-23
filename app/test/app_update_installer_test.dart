import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/platform/app_update.dart';
import 'package:jfzreader/core/platform/app_update_installer.dart';
import 'package:jfzreader/core/platform/app_version.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android updater verifies the APK before opening the installer',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'jfzreader-update-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final bytes = List<int>.generate(4096, (index) => index % 251);
      final stages = <AppUpdateInstallStage>[];
      String? openedPath;
      final installer = AndroidAppUpdateInstaller(
        artifactStreamLoader: (_, _) =>
            Stream.fromIterable([bytes.sublist(0, 2048), bytes.sublist(2048)]),
        temporaryDirectoryProvider: () async => temporaryDirectory,
        installPermissionCheck: () async {},
        nativeInstaller: (path) async => openedPath = path,
      );

      await installer.install(
        _update(bytes: bytes),
        onProgress: (progress) => stages.add(progress.stage),
      );

      expect(openedPath, isNotNull);
      expect(await File(openedPath!).readAsBytes(), bytes);
      expect(stages, containsAllInOrder(AppUpdateInstallStage.values));
      expect(
        Directory('${temporaryDirectory.path}/jfzreader-updates')
            .listSync()
            .whereType<File>()
            .any((file) => file.path.endsWith('.part')),
        isFalse,
      );
    },
  );

  test('Android updater rejects a checksum mismatch', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'jfzreader-update-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final bytes = List<int>.generate(128, (index) => index);
    var installerOpened = false;
    final installer = AndroidAppUpdateInstaller(
      artifactStreamLoader: (_, _) => Stream.value(bytes),
      temporaryDirectoryProvider: () async => temporaryDirectory,
      installPermissionCheck: () async {},
      nativeInstaller: (_) async => installerOpened = true,
    );

    await expectLater(
      installer.install(
        _update(bytes: bytes, sha256Override: List.filled(64, '0').join()),
      ),
      throwsFormatException,
    );

    expect(installerOpened, isFalse);
    expect(
      Directory('${temporaryDirectory.path}/jfzreader-updates').listSync(),
      isEmpty,
    );
  });

  test('Android updater requests install access before downloading', () async {
    final bytes = [1, 2, 3];
    var downloadStarted = false;
    final installer = AndroidAppUpdateInstaller(
      artifactStreamLoader: (_, _) {
        downloadStarted = true;
        return Stream.value(bytes);
      },
      installPermissionCheck: () async =>
          throw PlatformException(code: 'INSTALL_PERMISSION_REQUIRED'),
      nativeInstaller: (_) async {},
    );

    await expectLater(
      installer.install(_update(bytes: bytes)),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'INSTALL_PERMISSION_REQUIRED',
        ),
      ),
    );
    expect(downloadStarted, isFalse);
  });

  test('macOS updater delegates installation to Sparkle', () async {
    const channel = MethodChannel('jfzreader/test-sparkle');
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final stages = <AppUpdateInstallStage>[];

    await const MacOsSparkleUpdateInstaller(channel: channel).install(
      _macUpdate(),
      onProgress: (progress) => stages.add(progress.stage),
    );

    expect(receivedCall?.method, 'checkForUpdates');
    expect(stages, [AppUpdateInstallStage.openingInstaller]);
  });
}

AppUpdateCheck _update({required List<int> bytes, String? sha256Override}) {
  return AppUpdateCheck(
    installedVersion: const AppVersion(name: '1.0.0', buildNumber: '4'),
    latestVersion: const AppVersion(name: '1.0.0', buildNumber: '5'),
    platform: AppUpdatePlatform.android,
    updateAvailable: true,
    releasePageUri: Uri.parse(
      'https://github.com/troyt-666/novelia-mobile/releases/tag/v1.0.0+5',
    ),
    artifact: AppUpdateArtifact(
      uri: Uri.parse(
        'https://github.com/troyt-666/novelia-mobile/releases/download/'
        'v1.0.0+5/JFZ-Reader-v1.0.0+5-android.apk',
      ),
      size: bytes.length,
      sha256: sha256Override ?? sha256.convert(bytes).toString(),
    ),
    altStoreSourceUri: Uri.parse(defaultAltStoreSourceUri),
  );
}

AppUpdateCheck _macUpdate() {
  return AppUpdateCheck(
    installedVersion: const AppVersion(name: '1.0.0', buildNumber: '4'),
    latestVersion: const AppVersion(name: '1.0.0', buildNumber: '5'),
    platform: AppUpdatePlatform.macos,
    updateAvailable: true,
    releasePageUri: Uri.parse(
      'https://github.com/troyt-666/novelia-mobile/releases/tag/v1.0.0+5',
    ),
    artifact: AppUpdateArtifact(
      uri: Uri.parse(
        'https://github.com/troyt-666/novelia-mobile/releases/download/'
        'v1.0.0+5/JFZ-Reader-v1.0.0+5-macos.dmg',
      ),
      size: 100,
      sha256: List.filled(64, 'a').join(),
    ),
    altStoreSourceUri: Uri.parse(defaultAltStoreSourceUri),
  );
}
