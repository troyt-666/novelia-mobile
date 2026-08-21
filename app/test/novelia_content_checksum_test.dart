import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/gateway/novelia/novelia_content_checksum.dart';

void main() {
  test('matches known SHA-256 vectors of jsonEncode output', () {
    expect(
      noveliaContentChecksum(''),
      '12ae32cb1ec02d01eda3581b127c1fee3b0dc53572ed6baf239721a03d82e126',
    );
    expect(
      noveliaContentChecksum('abc'),
      '6cc43f858fbb763301637b5af970e2a46b46f461f27e5a0f41e009c59b827b25',
    );
    expect(
      noveliaContentChecksum({'a': 1}),
      '015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862',
    );
    expect(
      noveliaContentChecksum(null),
      '74234e98afe7498fb5daf1f36ac2d78acc339464f950703b8c019892f982b90b',
    );
  });

  test('recognizes 64-character lowercase hex revisions', () {
    expect(isNoveliaSha256Revision(noveliaContentChecksum('abc')), isTrue);
    expect(isNoveliaSha256Revision('r1'), isFalse);
    expect(isNoveliaSha256Revision(''), isFalse);
    expect(isNoveliaSha256Revision(null), isFalse);
  });
}
