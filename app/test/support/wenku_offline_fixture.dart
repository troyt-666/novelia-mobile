import 'dart:typed_data';

import 'package:archive/archive.dart';

Uint8List wenkuOfflineEpub({
  String title = '离线列车 · 第一卷',
  bool longChapter = false,
  String extraBody = '',
}) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string('META-INF/container.xml', '''
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles><rootfile full-path="book/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''),
    )
    ..addFile(
      ArchiveFile.string('book/package.opf', '''
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>$title</dc:title></metadata>
  <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="chapter"/></spine>
</package>'''),
    )
    ..addFile(
      ArchiveFile.string('book/chapter.xhtml', '''
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head><body>
<h1>离线列车</h1><p>即使没有网络，下载的故事也应该继续。</p>
<p style="opacity:0.4;">ネットがなくても、物語は続く。</p>
${longChapter ? List.filled(100, '<p>这是用来检查离线续读位置的长篇正文。</p>').join() : ''}
$extraBody
</body></html>'''),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
