import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../gateway/novelia/novelia_illustration_loader.dart';
import 'wenku_epub_document.dart';

/// Embed external illustrations in the publication itself. Data URIs also work
/// in inline styles and SVG image elements without inventing manifest paths.
class WenkuEpubImages {
  WenkuEpubImages(Uint8List bytes) {
    // Apply the reader's entry-count, expanded-size and path validation first.
    WenkuEpubDocument.parse(bytes);
    _archive = ZipDecoder().decodeBytes(bytes, verify: true);
    for (final file in _archive) {
      if (!file.isFile) continue;
      final lower = file.name.toLowerCase();
      if (lower.endsWith('.css')) {
        _css[file.name] = utf8.decode(file.content);
        _collectCss(_css[file.name]!);
      } else if (const [
        '.xhtml',
        '.html',
        '.htm',
        '.svg',
      ].any(lower.endsWith)) {
        final document = XmlDocument.parse(utf8.decode(file.content));
        _documents[file.name] = document;
        for (final element in document.descendants.whereType<XmlElement>()) {
          final name = element.name.local.toLowerCase();
          for (final attr in element.attributes) {
            final key = attr.name.local.toLowerCase();
            if ((name == 'img' && key == 'src') ||
                (name == 'image' && key == 'href') ||
                key == 'poster' ||
                (name == 'object' && key == 'data')) {
              _collect(attr.value);
            }
            if ((name == 'img' || name == 'source') && key == 'srcset') {
              for (final candidate in _srcset(attr.value)) {
                _collect(candidate.$1);
              }
            }
            if (key == 'style') _collectCss(attr.value);
          }
          if (name == 'style') _collectCss(element.innerText);
        }
      }
    }
  }

  late final Archive _archive;
  final _documents = <String, XmlDocument>{};
  final _css = <String, String>{};
  final _urls = <String, Uri>{};
  final _referenceCounts = <String, int>{};
  int get missingCount => _urls.length;
  static final _cssUrl = RegExp(r'''url\(\s*(['"]?)([^)'"\s]+)\1\s*\)''');

  void _collect(String value) {
    final uri = Uri.tryParse(value.startsWith('//') ? 'https:$value' : value);
    if (uri != null &&
        const ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty) {
      _urls[value] = uri;
      _referenceCounts[value] = (_referenceCounts[value] ?? 0) + 1;
    }
  }

  void _collectCss(String css) {
    for (final match in _cssUrl.allMatches(css)) {
      final value = match.group(2)!;
      // Fonts are separate publication resources, not illustrations.
      if (RegExp(
        r'\.(woff2?|ttf|otf|eot)(\?|$)',
        caseSensitive: false,
      ).hasMatch(value)) {
        continue;
      }
      _collect(value);
    }
  }

  static List<(String, String)> _srcset(String value) {
    final entries = <(String, String)>[];
    var rest = value.trim();
    while (rest.isNotEmpty) {
      rest = rest.replaceFirst(RegExp(r'^[,\s]+'), '');
      if (rest.isEmpty) break;
      final match =
          (rest.startsWith('data:')
                  ? RegExp(r'^data:[^,]*,[^\s,]+')
                  : RegExp(r'^[^\s,]+'))
              .firstMatch(rest);
      if (match == null) break;
      final url = match.group(0)!;
      rest = rest.substring(match.end);
      final comma = rest.indexOf(',');
      final descriptor = comma < 0
          ? rest.trim()
          : rest.substring(0, comma).trim();
      entries.add((url, descriptor));
      rest = comma < 0 ? '' : rest.substring(comma + 1);
    }
    return entries;
  }

  Future<({Uint8List bytes, int missing})> download(
    NoveliaIllustrationLoader loader, {
    void Function()? checkCancelled,
  }) async {
    final replacements = <String, String>{};
    final fetched = <Uri, String>{};
    var expanded = _archive.files.fold<int>(0, (n, f) => n + f.size);
    for (final entry in _urls.entries) {
      checkCancelled?.call();
      try {
        var data = fetched[entry.value];
        if (data == null) {
          final bytes = await loader.load(entry.value);
          data = 'data:${_mime(bytes)};base64,${base64Encode(bytes)}';
          fetched[entry.value] = data;
        }
        expanded += data.length * _referenceCounts[entry.key]!;
        if (expanded > WenkuEpubDocument.maximumExpandedBytes) break;
        replacements[entry.key] = data;
      } on Object {
        // Keep downloaded text and successful images. Retry only missing URLs.
        break;
      }
    }
    checkCancelled?.call();
    String css(String value) => value.replaceAllMapped(_cssUrl, (match) {
      final replacement = replacements[match.group(2)];
      return replacement == null ? match.group(0)! : 'url("$replacement")';
    });
    for (final doc in _documents.values) {
      for (final element in doc.descendants.whereType<XmlElement>().toList()) {
        for (final attr in element.attributes) {
          if (attr.name.local == 'style') {
            attr.value = css(attr.value);
          } else if (attr.name.local == 'srcset') {
            attr.value = [
              for (final candidate in _srcset(attr.value))
                '${replacements[candidate.$1] ?? candidate.$1} ${candidate.$2}'
                    .trim(),
            ].join(', ');
          } else if (replacements.containsKey(attr.value) &&
              ((element.name.local == 'img' && attr.name.local == 'src') ||
                  (element.name.local == 'image' &&
                      attr.name.local == 'href') ||
                  attr.name.local == 'poster' ||
                  (element.name.local == 'object' &&
                      attr.name.local == 'data'))) {
            attr.value = replacements[attr.value]!;
          }
        }
        if (element.name.local == 'style') {
          final rewritten = css(element.innerText);
          element.children
            ..clear()
            ..add(XmlText(rewritten));
        }
      }
    }
    final output = Archive();
    for (final file in _archive) {
      final document = _documents[file.name];
      final stylesheet = _css[file.name];
      output.addFile(
        document != null
            ? ArchiveFile.string(file.name, document.toXmlString())
            : stylesheet != null
            ? ArchiveFile.string(file.name, css(stylesheet))
            : file,
      );
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(output));
    WenkuEpubDocument.parse(bytes);
    return (bytes: bytes, missing: _urls.length - replacements.length);
  }

  static String _mime(Uint8List bytes) {
    if (utf8
        .decode(bytes.take(256).toList(), allowMalformed: true)
        .trimLeft()
        .startsWith('<')) {
      return 'image/svg+xml';
    }
    if (bytes.length >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50) {
      return 'image/png';
    }
    if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8) {
      return 'image/jpeg';
    }
    if (bytes.length >= 4 &&
        ascii.decode(bytes.sublist(0, 3), allowInvalid: true) == 'GIF') {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    if (bytes.length >= 12 &&
        ascii
            .decode(bytes.sublist(4, 12), allowInvalid: true)
            .contains('avif')) {
      return 'image/avif';
    }
    return 'image/bmp';
  }
}
