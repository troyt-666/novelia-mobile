import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/gateway/novelia/novelia_request_policy.dart';

void main() {
  test('allows production hosts over HTTPS and loopback over HTTP', () {
    expect(
      isAllowedNoveliaRequestUri(Uri.parse('https://n.novelia.cc/api/novel')),
      isTrue,
    );
    expect(
      isAllowedNoveliaRequestUri(
        Uri.parse('https://auth.novelia.cc/api/v1/auth/login'),
      ),
      isTrue,
    );
    expect(
      isAllowedNoveliaRequestUri(Uri.parse('http://127.0.0.1:8123/api/novel')),
      isTrue,
    );
    expect(
      isAllowedNoveliaRequestUri(Uri.parse('http://localhost/api/novel')),
      isTrue,
    );
  });

  test('rejects cleartext and off-allowlist hosts', () {
    expect(
      isAllowedNoveliaRequestUri(Uri.parse('http://n.novelia.cc/api/novel')),
      isFalse,
    );
    expect(
      isAllowedNoveliaRequestUri(Uri.parse('https://evil.example/api/novel')),
      isFalse,
    );
  });
}
