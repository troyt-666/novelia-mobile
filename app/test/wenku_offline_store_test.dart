import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/wenku/wenku_epub_store.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';

import 'support/wenku_offline_fixture.dart';

void main() {
  late Directory root;
  late WenkuEpubStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wenku-offline-');
    store = WenkuEpubStore(rootDirectory: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'downloads are discoverable after restart with their saved order',
    () async {
      for (final order in WenkuBilingualOrder.values) {
        await store.save(
          WenkuEpubRequest(
            novelId: 'fixture-novel',
            volumeId: '第一卷.epub',
            order: order,
            providers: const [WenkuTranslationProvider.sakura],
            filename: '第一卷.epub',
          ),
          wenkuOfflineEpub(),
          title: '离线列车',
        );
      }
      final restarted = WenkuEpubStore(rootDirectory: () async => root);
      final downloads = await restarted.listDownloads();
      expect(downloads, hasLength(2));
      expect(
        downloads.map((item) => item.order),
        unorderedEquals(WenkuBilingualOrder.values),
      );
      expect(downloads.map((item) => item.title), everyElement('离线列车'));
      expect(downloads.map((item) => item.volumeId), everyElement('第一卷.epub'));
      for (final download in downloads) {
        final document = await restarted.openDownload(download);
        expect(document.title, '离线列车 · 第一卷');
        expect(
          document.htmlForSpine(
            0,
            dark: false,
            fontSize: 18,
            japaneseFirst: false,
          ),
          contains('即使没有网络'),
        );
      }
    },
  );

  test(
    'old downloads and broken indexes recover without deleting EPUBs',
    () async {
      final directory = await Directory('${root.path}/wenku').create();
      final legacy = File('${directory.path}/0123456789abcdef0123.epub');
      await legacy.writeAsBytes(wenkuOfflineEpub());
      final brokenIndex = File('${directory.path}/1123456789abcdef0123.epub');
      await brokenIndex.writeAsBytes(wenkuOfflineEpub(title: '另一部旧下载'));
      await File('${brokenIndex.path}.json').writeAsString('{broken');
      final damaged = File('${directory.path}/damaged.epub');
      await damaged.writeAsString('truncated');
      await File(
        '${directory.path}/unfinished.epub.part',
      ).writeAsBytes(wenkuOfflineEpub());

      final downloads = await store.listDownloads();
      expect(downloads, hasLength(2));
      expect(downloads.map((item) => item.order), everyElement(isNull));
      expect(
        downloads.map((item) => item.title),
        unorderedEquals(['离线列车 · 第一卷', '另一部旧下载']),
      );
      expect((await store.openDownload(downloads.first)).spineLength, 1);
      expect(await damaged.exists(), isTrue);
      expect(await legacy.exists(), isTrue);
      expect(await store.listDownloads(), hasLength(2));
    },
  );

  test(
    'empty storage is usable and stale entries do not hide other books',
    () async {
      expect(await store.listDownloads(), isEmpty);
      final directory = await Directory('${root.path}/wenku').create();
      final file = File('${directory.path}/0123456789abcdef0123.epub');
      await file.writeAsBytes(wenkuOfflineEpub());
      final download = (await store.listDownloads()).single;
      await file.delete();
      expect(await store.listDownloads(), isEmpty);
      await expectLater(
        store.openDownload(download),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
