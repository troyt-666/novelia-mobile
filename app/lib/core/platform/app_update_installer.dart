import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_update.dart';

enum AppUpdateInstallStage { downloading, verifying, openingInstaller }

class AppUpdateInstallProgress {
  const AppUpdateInstallProgress({
    required this.stage,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final AppUpdateInstallStage stage;
  final int receivedBytes;
  final int totalBytes;

  double get fraction =>
      totalBytes == 0 ? 0 : (receivedBytes / totalBytes).clamp(0, 1).toDouble();
}

typedef AppUpdateProgressChanged =
    void Function(AppUpdateInstallProgress value);

abstract interface class AppUpdateInstaller {
  Future<void> install(
    AppUpdateCheck update, {
    AppUpdateProgressChanged? onProgress,
  });
}

/// Hands macOS updates to Sparkle, which verifies the Ed25519-signed DMG,
/// replaces the sandboxed application safely, and relaunches it.
class MacOsSparkleUpdateInstaller implements AppUpdateInstaller {
  const MacOsSparkleUpdateInstaller({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel(
            'io.github.troyt666.jfzreader/app_update_installer',
          );

  final MethodChannel _channel;

  @override
  Future<void> install(
    AppUpdateCheck update, {
    AppUpdateProgressChanged? onProgress,
  }) async {
    if (update.platform != AppUpdatePlatform.macos) {
      throw ArgumentError('The Sparkle installer only accepts macOS updates.');
    }
    onProgress?.call(
      AppUpdateInstallProgress(
        stage: AppUpdateInstallStage.openingInstaller,
        receivedBytes: 0,
        totalBytes: update.artifact.size,
      ),
    );
    final opened = await _channel.invokeMethod<bool>('checkForUpdates');
    if (opened != true) {
      throw StateError('macOS could not open Sparkle.');
    }
  }
}

typedef UpdateArtifactStreamLoader =
    Stream<List<int>> Function(Uri uri, int expectedSize);
typedef UpdateTemporaryDirectoryProvider = Future<Directory> Function();
typedef NativeInstallPermissionCheck = Future<void> Function();
typedef NativeApkInstaller = Future<void> Function(String apkPath);

/// Downloads and verifies the signed Android release before opening Android's
/// system package installer. The APK stays in the application cache so the
/// installer can read it after control leaves Flutter.
class AndroidAppUpdateInstaller implements AppUpdateInstaller {
  AndroidAppUpdateInstaller({
    UpdateArtifactStreamLoader? artifactStreamLoader,
    UpdateTemporaryDirectoryProvider? temporaryDirectoryProvider,
    NativeInstallPermissionCheck? installPermissionCheck,
    NativeApkInstaller? nativeInstaller,
  }) : _artifactStreamLoader = artifactStreamLoader ?? _downloadArtifact,
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _installPermissionCheck =
           installPermissionCheck ?? _ensureInstallPermission,
       _nativeInstaller = nativeInstaller ?? _openNativeInstaller;

  static const _channel = MethodChannel(
    'io.github.troyt666.jfzreader/app_update_installer',
  );

  final UpdateArtifactStreamLoader _artifactStreamLoader;
  final UpdateTemporaryDirectoryProvider _temporaryDirectoryProvider;
  final NativeInstallPermissionCheck _installPermissionCheck;
  final NativeApkInstaller _nativeInstaller;

  @override
  Future<void> install(
    AppUpdateCheck update, {
    AppUpdateProgressChanged? onProgress,
  }) async {
    if (update.platform != AppUpdatePlatform.android) {
      throw ArgumentError(
        'The Android installer only accepts Android updates.',
      );
    }
    final artifact = update.artifact;
    if (artifact.uri.scheme != 'https') {
      throw const FormatException('The Android update must use HTTPS.');
    }
    await _installPermissionCheck();

    final temporaryRoot = await _temporaryDirectoryProvider();
    final updateDirectory = Directory(
      path.join(temporaryRoot.path, 'jfzreader-updates'),
    );
    await updateDirectory.create(recursive: true);
    await _clearOldUpdates(updateDirectory);

    final version = update.latestVersion;
    final fileName = 'JFZ-Reader-${version.name}+${version.buildNumber}.apk';
    final apkFile = File(path.join(updateDirectory.path, fileName));
    final partialFile = File('${apkFile.path}.part');
    try {
      onProgress?.call(
        AppUpdateInstallProgress(
          stage: AppUpdateInstallStage.downloading,
          receivedBytes: 0,
          totalBytes: artifact.size,
        ),
      );
      final digestOutput = _DigestOutput();
      final digestInput = sha256.startChunkedConversion(digestOutput);
      final fileOutput = partialFile.openWrite();
      var receivedBytes = 0;
      try {
        await for (final chunk in _artifactStreamLoader(
          artifact.uri,
          artifact.size,
        ).timeout(const Duration(seconds: 30))) {
          receivedBytes += chunk.length;
          if (receivedBytes > artifact.size) {
            throw const FormatException(
              'The APK download is larger than expected.',
            );
          }
          digestInput.add(chunk);
          fileOutput.add(chunk);
          onProgress?.call(
            AppUpdateInstallProgress(
              stage: AppUpdateInstallStage.downloading,
              receivedBytes: receivedBytes,
              totalBytes: artifact.size,
            ),
          );
        }
        await fileOutput.flush();
        await fileOutput.close();
        digestInput.close();
      } on Object {
        await fileOutput.close();
        rethrow;
      }

      if (receivedBytes != artifact.size) {
        throw const FormatException('The APK download is incomplete.');
      }
      onProgress?.call(
        AppUpdateInstallProgress(
          stage: AppUpdateInstallStage.verifying,
          receivedBytes: receivedBytes,
          totalBytes: artifact.size,
        ),
      );
      if (digestOutput.value?.toString() != artifact.sha256) {
        throw const FormatException(
          'The APK checksum does not match the feed.',
        );
      }

      if (await apkFile.exists()) await apkFile.delete();
      await partialFile.rename(apkFile.path);
      onProgress?.call(
        AppUpdateInstallProgress(
          stage: AppUpdateInstallStage.openingInstaller,
          receivedBytes: receivedBytes,
          totalBytes: artifact.size,
        ),
      );
      await _nativeInstaller(apkFile.path);
    } on Object {
      if (await partialFile.exists()) await partialFile.delete();
      rethrow;
    }
  }

  static Stream<List<int>> _downloadArtifact(Uri uri, int expectedSize) async* {
    final client = HttpClient()..userAgent = 'JFZ-Reader-In-App-Updater/1';
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.android.package-archive',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'APK download returned HTTP ${response.statusCode}.',
          uri: uri,
        );
      }
      if (response.redirects.any(
        (redirect) => redirect.location.scheme != 'https',
      )) {
        throw const FormatException(
          'The APK download redirected away from HTTPS.',
        );
      }
      final declaredLength = response.contentLength;
      if (declaredLength >= 0 && declaredLength != expectedSize) {
        throw const FormatException(
          'The APK download size does not match the feed.',
        );
      }
      yield* response;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _clearOldUpdates(Directory directory) async {
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          (entry.path.endsWith('.apk') || entry.path.endsWith('.apk.part'))) {
        await entry.delete();
      }
    }
  }

  static Future<void> _openNativeInstaller(String apkPath) async {
    final opened = await _channel.invokeMethod<bool>('installApk', apkPath);
    if (opened != true) {
      throw StateError('Android could not open the package installer.');
    }
  }

  static Future<void> _ensureInstallPermission() async {
    final allowed = await _channel.invokeMethod<bool>(
      'ensureInstallPermission',
    );
    if (allowed != true) {
      throw StateError('Android did not grant package installation access.');
    }
  }
}

class _DigestOutput implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
