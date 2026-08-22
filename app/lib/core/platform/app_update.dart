import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_version.dart';

const defaultUpdateManifestUri =
    'https://troyt-666.github.io/novelia-mobile/latest.json';
const defaultAltStoreSourceUri =
    'https://troyt-666.github.io/novelia-mobile/altstore-source.json';
const defaultReleasesUri =
    'https://github.com/troyt-666/novelia-mobile/releases';
const _trustedReleasePath = '/troyt-666/novelia-mobile/releases/';

enum AppUpdatePlatform {
  android('android'),
  ios('ios'),
  macos('macos');

  const AppUpdatePlatform(this.manifestKey);

  final String manifestKey;

  static AppUpdatePlatform current() {
    if (Platform.isAndroid) return AppUpdatePlatform.android;
    if (Platform.isIOS) return AppUpdatePlatform.ios;
    if (Platform.isMacOS) return AppUpdatePlatform.macos;
    throw UnsupportedError('App updates are not configured for this platform.');
  }
}

typedef UpdateManifestLoader = Future<String> Function(Uri uri);

class AppUpdateManifest {
  const AppUpdateManifest({
    required this.version,
    required this.releasePageUri,
    required this.altStoreSourceUri,
    required this.downloadUris,
    this.releaseNotes = '',
  });

  factory AppUpdateManifest.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported update manifest schema.');
    }
    final versionName = _requiredString(json, 'version');
    final buildNumber = json['buildNumber'];
    if (buildNumber is! int || buildNumber < 0) {
      throw const FormatException('Invalid update build number.');
    }
    _parseVersion(versionName);

    final downloads = json['downloads'];
    if (downloads is! Map<String, Object?>) {
      throw const FormatException('Invalid update downloads.');
    }
    final downloadUris = <AppUpdatePlatform, Uri>{};
    for (final platform in AppUpdatePlatform.values) {
      final value = downloads[platform.manifestKey];
      if (value is! Map<String, Object?>) {
        throw FormatException('Missing ${platform.manifestKey} download.');
      }
      downloadUris[platform] = _requiredHttpsUri(value, 'url');
    }

    final releasePageUri = _requiredHttpsUri(json, 'releasePageUrl');
    _requireTrustedReleaseUri(releasePageUri, download: false);
    final altStoreSourceUri = _requiredHttpsUri(json, 'altStoreSourceUrl');
    if (altStoreSourceUri.toString() != defaultAltStoreSourceUri) {
      throw const FormatException('Untrusted AltStore source URL.');
    }
    for (final uri in downloadUris.values) {
      _requireTrustedReleaseUri(uri, download: true);
    }

    return AppUpdateManifest(
      version: AppVersion(
        name: versionName,
        buildNumber: buildNumber.toString(),
      ),
      releasePageUri: releasePageUri,
      altStoreSourceUri: altStoreSourceUri,
      downloadUris: Map.unmodifiable(downloadUris),
      releaseNotes: _optionalString(json, 'releaseNotes'),
    );
  }

  final AppVersion version;
  final Uri releasePageUri;
  final Uri altStoreSourceUri;
  final Map<AppUpdatePlatform, Uri> downloadUris;
  final String releaseNotes;

  Uri downloadUriFor(AppUpdatePlatform platform) {
    final uri = downloadUris[platform];
    if (uri == null) {
      throw StateError('No update download is configured for $platform.');
    }
    return uri;
  }
}

class AppUpdateCheck {
  const AppUpdateCheck({
    required this.installedVersion,
    required this.latestVersion,
    required this.platform,
    required this.updateAvailable,
    required this.releasePageUri,
    required this.downloadUri,
    required this.altStoreSourceUri,
    this.releaseNotes = '',
  });

  final AppVersion installedVersion;
  final AppVersion latestVersion;
  final AppUpdatePlatform platform;
  final bool updateAvailable;
  final Uri releasePageUri;
  final Uri downloadUri;
  final Uri altStoreSourceUri;
  final String releaseNotes;
}

abstract interface class AppUpdateChecker {
  Future<AppUpdateCheck> check(AppVersion installedVersion);
}

class GitHubAppUpdateChecker implements AppUpdateChecker {
  GitHubAppUpdateChecker({
    required this.platform,
    Uri? manifestUri,
    UpdateManifestLoader? manifestLoader,
  }) : manifestUri = manifestUri ?? Uri.parse(defaultUpdateManifestUri),
       _manifestLoader = manifestLoader ?? _loadHttpsManifest;

  final AppUpdatePlatform platform;
  final Uri manifestUri;
  final UpdateManifestLoader _manifestLoader;

  @override
  Future<AppUpdateCheck> check(AppVersion installedVersion) async {
    _parseVersion(installedVersion.name);
    _parseBuildNumber(installedVersion.buildNumber);
    if (manifestUri.scheme != 'https') {
      throw const FormatException('The update feed must use HTTPS.');
    }

    final body = await _manifestLoader(manifestUri);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('The update manifest must be an object.');
    }
    final manifest = AppUpdateManifest.fromJson(decoded);
    return AppUpdateCheck(
      installedVersion: installedVersion,
      latestVersion: manifest.version,
      platform: platform,
      updateAvailable: isVersionNewer(
        candidate: manifest.version,
        installed: installedVersion,
      ),
      releasePageUri: manifest.releasePageUri,
      downloadUri: manifest.downloadUriFor(platform),
      altStoreSourceUri: manifest.altStoreSourceUri,
      releaseNotes: manifest.releaseNotes,
    );
  }
}

bool isVersionNewer({
  required AppVersion candidate,
  required AppVersion installed,
}) {
  final candidateParts = _parseVersion(candidate.name);
  final installedParts = _parseVersion(installed.name);
  for (var index = 0; index < candidateParts.length; index += 1) {
    final comparison = candidateParts[index].compareTo(installedParts[index]);
    if (comparison != 0) return comparison > 0;
  }
  return _parseBuildNumber(candidate.buildNumber) >
      _parseBuildNumber(installed.buildNumber);
}

Future<String> _loadHttpsManifest(Uri uri) async {
  if (uri.scheme != 'https') {
    throw const FormatException('The update feed must use HTTPS.');
  }
  final client = HttpClient()..userAgent = 'JFZ-Reader-Update-Check/1';
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 8));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Update feed returned HTTP ${response.statusCode}.',
        uri: uri,
      );
    }
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 8));
    if (body.length > 256 * 1024) {
      throw const FormatException('The update manifest is too large.');
    }
    return body;
  } finally {
    client.close(force: true);
  }
}

List<int> _parseVersion(String value) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(value.trim());
  if (match == null) throw const FormatException('Invalid app version.');
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}

int _parseBuildNumber(String value) {
  final parsed = int.tryParse(value.trim());
  if (parsed == null || parsed < 0) {
    throw const FormatException('Invalid app build number.');
  }
  return parsed;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing update manifest field: $key.');
  }
  return value.trim();
}

String _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return '';
  if (value is! String) {
    throw FormatException('Invalid update manifest field: $key.');
  }
  return value.trim();
}

Uri _requiredHttpsUri(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw FormatException('Update manifest field $key must be an HTTPS URL.');
  }
  return uri;
}

void _requireTrustedReleaseUri(Uri uri, {required bool download}) {
  final requiredPath = download
      ? '${_trustedReleasePath}download/'
      : _trustedReleasePath;
  if (uri.host != 'github.com' || !uri.path.startsWith(requiredPath)) {
    throw const FormatException('Untrusted GitHub release URL.');
  }
}
