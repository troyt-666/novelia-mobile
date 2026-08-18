import 'package:flutter/services.dart';

abstract interface class ExternalLinkLauncher {
  Future<void> open(Uri uri);
}

/// Opens an HTTP(S) URL in the platform's default external browser.
///
/// The native runners implement this small channel directly so the reader does
/// not need a third-party launcher plugin or an embedded browser surface.
class MethodChannelExternalLinkLauncher implements ExternalLinkLauncher {
  const MethodChannelExternalLinkLauncher();

  static const _channel = MethodChannel(
    'io.github.troyt666.jfzreader/external_links',
  );

  @override
  Future<void> open(Uri uri) async {
    if (!uri.hasScheme || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw ArgumentError.value(uri, 'uri', 'Only HTTP(S) links are allowed.');
    }
    final opened = await _channel.invokeMethod<bool>('open', uri.toString());
    if (opened != true) {
      throw StateError('The platform could not open the external link.');
    }
  }
}
