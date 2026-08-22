import 'package:flutter/services.dart';

class AppVersion {
  const AppVersion({required this.name, required this.buildNumber});

  const AppVersion.unavailable() : name = '', buildNumber = '';

  final String name;
  final String buildNumber;

  String get display {
    if (name.isEmpty) return '版本未知';
    if (buildNumber.isEmpty) return name;
    return '$name+$buildNumber';
  }
}

class InstalledAppVersion {
  const InstalledAppVersion();

  static const _channel = MethodChannel(
    'io.github.troyt666.jfzreader/app_version',
  );

  Future<AppVersion> load() async {
    try {
      final values = await _channel.invokeMapMethod<String, String>('get');
      final name = values?['name']?.trim() ?? '';
      final buildNumber = values?['buildNumber']?.trim() ?? '';
      if (name.isEmpty) return const AppVersion.unavailable();
      return AppVersion(name: name, buildNumber: buildNumber);
    } on PlatformException {
      return const AppVersion.unavailable();
    } on MissingPluginException {
      return const AppVersion.unavailable();
    }
  }
}
