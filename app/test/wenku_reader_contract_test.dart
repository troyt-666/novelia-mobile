import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/wenku/wenku_epub_document.dart';
import 'package:jfzreader/features/wenku/wenku_epub_store.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';

void main() {
  test('parses EPUB navigation and builds a sanitized Japanese document', () {
    final document = WenkuEpubDocument.parse(_fixtureEpub());

    expect(document.title, '夜行列车');
    expect(document.spineLength, 2);
    expect(document.toc.single.title, '第一章');
    expect(document.toc.single.spineIndex, 1);
    expect(document.toc.single.fragment, 'start');

    final html = document.htmlForSpine(
      1,
      dark: false,
      fontSize: 18,
      japaneseFirst: true,
      palette: WenkuEpubPalette.sepia,
      japaneseOpacity: .9,
    );
    expect(html, contains('<ruby>鉄<rt>てつ</rt></ruby>'));
    expect(html, contains('p[style*="opacity"]'));
    expect(html, contains('writing-mode: horizontal-tb'));
    expect(html, contains('column-width: 100vw !important'));
    expect(
      html,
      contains('column-gap: calc(var(--reader-inline-padding) * 2)'),
    );
    expect(html, contains('data:image/jpeg;base64,'));
    expect(html, contains('reader-visual-block'));
    expect(html, contains('break-inside: avoid-column !important'));
    expect(html, contains('Content-Security-Policy'));
    expect(html, contains('readerNext'));
    expect(html, contains('--reader-background: #f4ecd8'));
    expect(html, contains('--reader-japanese-opacity: 0.90'));
    expect(html, contains('window.readerSetAppearance'));
    expect(html, contains("event.key === 'ArrowLeft'"));
    expect(html, contains("event.key === 'ArrowRight'"));
    expect(
      html,
      contains(
        'const pageCount = () => Math.max(1, Math.ceil(contentLength() / pageDelta()))',
      ),
    );
    expect(
      html,
      contains('moveToPage(Math.floor(normalized * lastPageIndex()), false)'),
    );
    expect(html, contains('logicalPage = pageAtOffset(current())'));
    expect(
      html,
      contains(
        'Promise.all([fontReady, ...Array.from(document.images, imageReady)])',
      ),
    );
    expect(html, contains("'left:' + (normalizedWidth - 1) + 'px!important'"));
    expect(html, contains('document.body.appendChild(extentGuard)'));
    expect(html, contains("sendAction(dx < 0 ? 'next' : 'previous')"));
    expect(html, contains("ratio < .36) sendAction('previous')"));
    expect(html, contains('const originalIsFirst = true'));
    expect(html, isNot(contains('alert(')));
    expect(html, isNot(contains('onload=')));

    final imageHtml = document.htmlForSpine(
      0,
      dark: false,
      fontSize: 18,
      japaneseFirst: true,
    );
    expect(imageHtml, contains('reader-image-only'));
    expect(imageHtml, contains('overflow: hidden !important'));
  });

  test('publication CSS cannot escape the reader style element', () {
    final document = WenkuEpubDocument.parse(
      _fixtureEpub(
        css: '.safe { color: red; }</style><script>attack()</script><style>',
      ),
    );

    final html = document.htmlForSpine(
      1,
      dark: false,
      fontSize: 18,
      japaneseFirst: true,
    );

    expect(html, isNot(contains('</style><script>attack()')));
    expect(html, contains(r'<\/style><script>attack()'));
  });

  test('saved EPUB is reused by a fresh store instance', () async {
    final root = await Directory.systemTemp.createTemp('wenku-store-test-');
    addTearDown(() => root.delete(recursive: true));
    const request = WenkuEpubRequest(
      novelId: 'novel-1',
      volumeId: 'volume-1.epub',
      order: WenkuBilingualOrder.chineseFirst,
      providers: [WenkuTranslationProvider.sakura],
      filename: 'volume-1.epub',
    );
    final bytes = _fixtureEpub();

    await WenkuEpubStore(rootDirectory: () async => root).save(request, bytes);
    final restored = await WenkuEpubStore(
      rootDirectory: () async => root,
    ).load(request);

    expect(restored, bytes);
  });

  test('truncated cached EPUB is evicted instead of reused', () async {
    final root = await Directory.systemTemp.createTemp('wenku-store-test-');
    addTearDown(() => root.delete(recursive: true));
    const request = WenkuEpubRequest(
      novelId: 'novel-1',
      volumeId: 'volume-1.epub',
      order: WenkuBilingualOrder.chineseFirst,
      providers: [WenkuTranslationProvider.sakura],
      filename: 'volume-1.epub',
    );
    final bytes = _fixtureEpub();
    final store = WenkuEpubStore(rootDirectory: () async => root);
    final cached = await store.save(request, bytes);
    await cached.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2), flush: true);

    expect(await store.load(request), isNull);
    expect(await cached.exists(), isFalse);
  });
}

Uint8List _fixtureEpub({
  String css = '.publisher-class { letter-spacing: .1em; }',
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.noCompress(
        'mimetype',
        'application/epub+zip'.length,
        'application/epub+zip'.codeUnits,
      ),
    )
    ..addFile(
      ArchiveFile.string('META-INF/container.xml', '''<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/package.opf',
        '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>夜行列车</dc:title></metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="cover-page" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="css" href="style/book.css" media-type="text/css"/>
    <item id="image" href="images/cover.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine><itemref idref="cover-page"/><itemref idref="chapter"/></spine>
</package>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/text/cover.xhtml',
        '''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>封面</title></head><body class="p-cover"><div class="main"><p><img src="../images/cover.jpg"/></p></div></body></html>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/nav.xhtml',
        '''<html xmlns="http://www.w3.org/1999/xhtml"><body><nav><ol><li><a href="text/chapter.xhtml#start">第一章</a></li></ol></nav></body></html>''',
      ),
    )
    ..addFile(ArchiveFile.string('OEBPS/style/book.css', css))
    ..addFile(
      ArchiveFile.string(
        'OEBPS/text/chapter.xhtml',
        '''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title><script>alert('bad')</script></head><body onload="alert('bad')"><p id="start" style="opacity:0.4;"><ruby>鉄<rt>てつ</rt></ruby>道</p><p>铁路</p><img src="../images/cover.jpg"/></body></html>''',
      ),
    )
    ..addFile(
      ArchiveFile.bytes('OEBPS/images/cover.jpg', [0xff, 0xd8, 0xff, 0xd9]),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
