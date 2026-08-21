import 'dart:io';

/// Production Novelia hosts. Loopback remains allowed so tests can inject
/// local HTTP servers. HTTPS is required for every non-loopback host.
const noveliaAllowedHosts = <String>{'n.novelia.cc', 'auth.novelia.cc'};

bool isAllowedNoveliaRequestUri(Uri uri) {
  final host = uri.host.trim();
  if (host.isEmpty) return false;
  if (_isLoopbackHost(host)) {
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
  if (uri.scheme != 'https') return false;
  return noveliaAllowedHosts.contains(host);
}

void pinNoveliaHttpRequest(HttpClientRequest request) {
  request.followRedirects = false;
}

bool _isLoopbackHost(String host) {
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return true;
  }
  return InternetAddress.tryParse(host)?.isLoopback ?? false;
}
