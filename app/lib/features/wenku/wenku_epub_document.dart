import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../gateway/novelia/novelia_gateway.dart';

enum WenkuEpubPalette {
  automatic,
  paper,
  sepia,
  eyeCare,
  lowLight,
  dark,
  black,
}

extension WenkuEpubPaletteStyle on WenkuEpubPalette {
  String get label => switch (this) {
    WenkuEpubPalette.automatic => '自动',
    WenkuEpubPalette.paper => '纸张',
    WenkuEpubPalette.sepia => '米黄',
    WenkuEpubPalette.eyeCare => '护眼',
    WenkuEpubPalette.lowLight => '低光',
    WenkuEpubPalette.dark => '深色',
    WenkuEpubPalette.black => '纯黑',
  };

  WenkuEpubColors resolve({required bool systemDark}) => switch (this) {
    WenkuEpubPalette.automatic =>
      systemDark
          ? const WenkuEpubColors('#171613', '#eee7da')
          : const WenkuEpubColors('#fbf8f1', '#292621'),
    WenkuEpubPalette.paper => const WenkuEpubColors('#fbf8f1', '#292621'),
    WenkuEpubPalette.sepia => const WenkuEpubColors('#f4ecd8', '#3a3024'),
    WenkuEpubPalette.eyeCare => const WenkuEpubColors('#dce8d2', '#263126'),
    WenkuEpubPalette.lowLight => const WenkuEpubColors('#d8d2c4', '#282622'),
    WenkuEpubPalette.dark => const WenkuEpubColors('#171613', '#eee7da'),
    WenkuEpubPalette.black => const WenkuEpubColors('#050505', '#dedbd4'),
  };
}

class WenkuEpubColors {
  const WenkuEpubColors(this.background, this.foreground);

  final String background;
  final String foreground;
}

class WenkuEpubTocEntry {
  const WenkuEpubTocEntry({
    required this.title,
    required this.spineIndex,
    this.fragment,
  });

  final String title;
  final int spineIndex;
  final String? fragment;
}

class WenkuEpubDocument {
  WenkuEpubDocument._(
    this.title,
    this.toc,
    this._spinePaths,
    this._entries,
    this._mediaTypes,
    this._publicationCss,
  );

  static const maximumEntryCount = 5000;
  static const maximumExpandedBytes = 256 * 1024 * 1024;

  final String title;
  final List<WenkuEpubTocEntry> toc;
  final List<String> _spinePaths;
  final Map<String, Uint8List> _entries;
  final Map<String, String> _mediaTypes;
  final String _publicationCss;

  int get spineLength => _spinePaths.length;

  static WenkuEpubDocument parse(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      if (archive.length > maximumEntryCount) {
        throw const FormatException('EPUB contains too many entries.');
      }
      final entries = <String, Uint8List>{};
      var expandedBytes = 0;
      for (final file in archive) {
        if (!file.isFile) continue;
        if (file.isSymbolicLink) {
          throw const FormatException('EPUB contains a symbolic link.');
        }
        final path = _archivePath(file.name);
        if (entries.containsKey(path)) {
          throw const FormatException('EPUB contains duplicate entry paths.');
        }
        expandedBytes += file.size;
        if (expandedBytes > maximumExpandedBytes) {
          throw const FormatException('EPUB expands beyond the safe limit.');
        }
        entries[path] = file.content;
      }

      final container = _xml(entries, 'META-INF/container.xml');
      final rootfile = container.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'rootfile')
          .map((element) => element.getAttribute('full-path'))
          .whereType<String>()
          .firstOrNull;
      if (rootfile == null) {
        throw const FormatException('EPUB container has no package document.');
      }
      final packagePath = _archivePath(rootfile);
      final packageDirectory = p.posix.dirname(packagePath);
      final package = _xml(entries, packagePath);

      final manifestById =
          <String, ({String path, String mediaType, String properties})>{};
      final mediaTypes = <String, String>{};
      for (final item in package.descendants.whereType<XmlElement>().where(
        (element) => element.name.local == 'item',
      )) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        if (id == null || href == null) continue;
        final path = _resolve(packageDirectory, Uri.decodeComponent(href));
        final mediaType = item.getAttribute('media-type') ?? _mimeFor(path);
        final properties = item.getAttribute('properties') ?? '';
        manifestById[id] = (
          path: path,
          mediaType: mediaType,
          properties: properties,
        );
        mediaTypes[path] = mediaType;
      }

      final spinePaths = <String>[];
      for (final itemref in package.descendants.whereType<XmlElement>().where(
        (element) => element.name.local == 'itemref',
      )) {
        final item = manifestById[itemref.getAttribute('idref')];
        if (item != null && entries.containsKey(item.path)) {
          spinePaths.add(item.path);
        }
      }
      if (spinePaths.isEmpty) {
        throw const FormatException('EPUB package has no readable spine.');
      }

      final css = StringBuffer();
      for (final item in manifestById.values.where(
        (item) => item.mediaType == 'text/css',
      )) {
        final data = entries[item.path];
        if (data == null) continue;
        final decoded = utf8.decode(data, allowMalformed: true);
        css.writeln(_rewriteCssUrls(decoded, item.path, entries, mediaTypes));
      }

      final navItem = manifestById.values
          .where((item) => item.properties.split(' ').contains('nav'))
          .firstOrNull;
      final toc = navItem == null
          ? const <WenkuEpubTocEntry>[]
          : _parseToc(entries, navItem.path, spinePaths);
      final packageTitle = package.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'title')
          .map((element) => element.innerText.trim())
          .where((value) => value.isNotEmpty)
          .firstOrNull;

      return WenkuEpubDocument._(
        packageTitle ?? '文库 EPUB',
        toc.isEmpty
            ? [
                for (var index = 0; index < spinePaths.length; index++)
                  WenkuEpubTocEntry(
                    title: '第 ${index + 1} 节',
                    spineIndex: index,
                  ),
              ]
            : toc,
        List.unmodifiable(spinePaths),
        Map.unmodifiable(entries),
        Map.unmodifiable(mediaTypes),
        css.toString(),
      );
    } on NoveliaGatewayException {
      rethrow;
    } on Object {
      throw const NoveliaGatewayException(
        NoveliaGatewayFailureKind.invalidResponse,
        'The downloaded EPUB structure could not be read safely.',
      );
    }
  }

  Future<String> htmlForSpineAsync(
    int index, {
    required bool dark,
    required double fontSize,
    required bool japaneseFirst,
    WenkuEpubPalette palette = WenkuEpubPalette.automatic,
    double japaneseOpacity = .68,
  }) {
    // ponytail: one document copy per chapter; retain a worker if large EPUB
    // transfer costs become significant in device profiles.
    return Isolate.run(
      () => htmlForSpine(
        index,
        dark: dark,
        fontSize: fontSize,
        japaneseFirst: japaneseFirst,
        palette: palette,
        japaneseOpacity: japaneseOpacity,
      ),
    );
  }

  String htmlForSpine(
    int index, {
    required bool dark,
    required double fontSize,
    required bool japaneseFirst,
    WenkuEpubPalette palette = WenkuEpubPalette.automatic,
    double japaneseOpacity = .68,
  }) {
    if (index < 0 || index >= _spinePaths.length) {
      throw RangeError.index(index, _spinePaths, 'index');
    }
    final spinePath = _spinePaths[index];
    final source = utf8.decode(_entries[spinePath]!, allowMalformed: true);
    final document = XmlDocument.parse(source);

    for (final script
        in document.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'script')
            .toList(growable: false)) {
      script.parent?.children.remove(script);
    }
    for (final element in document.descendants.whereType<XmlElement>()) {
      for (final attribute in element.attributes.toList(growable: false)) {
        if (attribute.name.local.toLowerCase().startsWith('on')) {
          element.attributes.remove(attribute);
        }
      }
      _inlineResource(element, 'src', spinePath);
      _inlineResource(element, 'poster', spinePath);
      if (element.name.local == 'image' || element.name.local == 'use') {
        _inlineResource(element, 'href', spinePath);
      }
      if (element.name.local == 'object') {
        _inlineResource(element, 'data', spinePath);
      }
    }

    final body = document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'body')
        .firstOrNull;
    if (body != null) {
      final visuals = body.descendants
          .whereType<XmlElement>()
          .where((element) {
            final name = element.name.local;
            return name == 'img' || name == 'svg';
          })
          .toList(growable: false);
      if (visuals.length == 1 && body.innerText.trim().isEmpty) {
        final classes = body.getAttribute('class')?.trim() ?? '';
        body.setAttribute(
          'class',
          classes.isEmpty ? 'reader-image-only' : '$classes reader-image-only',
        );
      }
      for (final visualContainer
          in body.descendants.whereType<XmlElement>().where((element) {
            final name = element.name.local;
            if (name != 'p' && name != 'figure') return false;
            if (element.innerText.trim().isNotEmpty) return false;
            return element.descendants.whereType<XmlElement>().any((child) {
              final childName = child.name.local;
              return childName == 'img' || childName == 'svg';
            });
          })) {
        final classes = visualContainer.getAttribute('class')?.trim() ?? '';
        visualContainer.setAttribute(
          'class',
          classes.isEmpty
              ? 'reader-visual-block'
              : '$classes reader-visual-block',
        );
      }
    }

    final html = document.toXmlString(pretty: false);
    final style = _readerCss(
      colors: palette.resolve(systemDark: dark),
      fontSize: fontSize,
      japaneseOpacity: japaneseOpacity,
      publicationCss: _publicationCss,
    );
    final additions =
        '''
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>$style</style>
''';
    final withHead = html.contains('</head>')
        ? html.replaceFirst('</head>', '$additions</head>')
        : html.replaceFirst(RegExp(r'<body\b'), '<head>$additions</head><body');
    return withHead.replaceFirst(
      '</body>',
      '${_readerScript(japaneseFirst: japaneseFirst)}</body>',
    );
  }

  void _inlineResource(XmlElement element, String localName, String spinePath) {
    final attribute = element.attributes
        .where((attribute) => attribute.name.local == localName)
        .firstOrNull;
    final value = attribute?.value;
    if (attribute == null || value == null || value.startsWith('data:')) return;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.hasScheme || value.startsWith('#')) return;
    final path = _resolve(
      p.posix.dirname(spinePath),
      Uri.decodeComponent(uri.path),
    );
    final data = _entries[path];
    if (data == null) return;
    attribute.value = _dataUri(data, _mediaTypes[path] ?? _mimeFor(path));
  }

  static XmlDocument _xml(Map<String, Uint8List> entries, String path) {
    final bytes = entries[path];
    if (bytes == null) throw FormatException('Missing EPUB entry: $path');
    return XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
  }

  static List<WenkuEpubTocEntry> _parseToc(
    Map<String, Uint8List> entries,
    String navPath,
    List<String> spinePaths,
  ) {
    final nav = _xml(entries, navPath);
    final directory = p.posix.dirname(navPath);
    final result = <WenkuEpubTocEntry>[];
    final seen = <String>{};
    for (final anchor in nav.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'a',
    )) {
      final href = anchor.getAttribute('href');
      if (href == null) continue;
      final uri = Uri.tryParse(href);
      if (uri == null || uri.hasScheme) continue;
      final path = _resolve(directory, Uri.decodeComponent(uri.path));
      final index = spinePaths.indexOf(path);
      final title = anchor.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
      final key = '$index#${uri.fragment}';
      if (index < 0 || title.isEmpty || !seen.add(key)) continue;
      result.add(
        WenkuEpubTocEntry(
          title: title,
          spineIndex: index,
          fragment: uri.fragment.isEmpty ? null : uri.fragment,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  static String _rewriteCssUrls(
    String css,
    String cssPath,
    Map<String, Uint8List> entries,
    Map<String, String> mediaTypes,
  ) => css.replaceAllMapped(RegExp(r'''url\(\s*(['"]?)([^)'"\s]+)\1\s*\)'''), (
    match,
  ) {
    final value = match.group(2)!;
    if (value.startsWith('data:') || value.startsWith('#')) {
      return match.group(0)!;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.hasScheme) return 'url()';
    final path = _resolve(
      p.posix.dirname(cssPath),
      Uri.decodeComponent(uri.path),
    );
    final data = entries[path];
    if (data == null) return 'url()';
    return 'url("${_dataUri(data, mediaTypes[path] ?? _mimeFor(path))}")';
  });

  static String _archivePath(String value) {
    final normalized = p.posix
        .normalize(value.replaceAll('\\', '/'))
        .replaceFirst(RegExp(r'^/+'), '');
    if (normalized.isEmpty ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw const FormatException('Unsafe EPUB archive path.');
    }
    return normalized;
  }

  static String _resolve(String directory, String value) =>
      _archivePath(p.posix.join(directory == '.' ? '' : directory, value));

  static String _dataUri(Uint8List bytes, String mimeType) =>
      'data:$mimeType;base64,${base64Encode(bytes)}';

  static String _mimeFor(String path) =>
      switch (p.posix.extension(path).toLowerCase()) {
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.png' => 'image/png',
        '.gif' => 'image/gif',
        '.webp' => 'image/webp',
        '.svg' => 'image/svg+xml',
        '.woff' => 'font/woff',
        '.woff2' => 'font/woff2',
        '.otf' => 'font/otf',
        '.ttf' => 'font/ttf',
        '.css' => 'text/css',
        _ => 'application/octet-stream',
      };
}

String _readerCss({
  required WenkuEpubColors colors,
  required double fontSize,
  required double japaneseOpacity,
  required String publicationCss,
}) {
  final background = colors.background;
  final foreground = colors.foreground;
  const pagination = '''
html {
  width: 100vw !important; height: 100vh !important;
  overflow: hidden !important;
}
body {
  box-sizing: border-box !important;
  width: 100vw !important;
  min-width: 0 !important;
  height: 100vh !important;
  min-height: 0 !important;
  overflow: visible !important;
  column-width: 100vw !important;
  column-gap: calc(var(--reader-inline-padding) * 2) !important;
  column-fill: auto !important;
  touch-action: pan-y;
}
''';
  return '''
${_cssForStyleElement(publicationCss)}
html {
  --reader-inline-padding: clamp(28px, 6vw, 72px);
  --reader-block-padding: clamp(60px, 8vh, 84px);
  --reader-background: $background;
  --reader-foreground: $foreground;
  --reader-japanese-opacity: ${japaneseOpacity.clamp(0.35, 1).toStringAsFixed(2)};
  writing-mode: horizontal-tb !important;
  -webkit-writing-mode: horizontal-tb !important;
  direction: ltr !important;
  background: var(--reader-background) !important;
}
body {
  box-sizing: border-box; background: var(--reader-background) !important; color: var(--reader-foreground) !important;
  font-family: "PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", "Yu Gothic", "Hiragino Kaku Gothic ProN", sans-serif !important;
  font-size: ${fontSize.toStringAsFixed(1)}px !important; line-height: 1.9 !important; letter-spacing: .015em;
  padding: var(--reader-block-padding) var(--reader-inline-padding) !important;
  margin: 0 !important; overflow-wrap: anywhere; word-break: normal;
  writing-mode: horizontal-tb !important; -webkit-writing-mode: horizontal-tb !important;
  direction: ltr !important;
}
$pagination
p { max-width: 100% !important; margin: .72em 0 !important; text-align: justify; }
body:not(.reader-image-only) p,
body:not(.reader-image-only) li,
body:not(.reader-image-only) h1,
body:not(.reader-image-only) h2,
body:not(.reader-image-only) h3,
body:not(.reader-image-only) h4,
body:not(.reader-image-only) h5,
body:not(.reader-image-only) h6 {
  white-space: normal !important;
  overflow-wrap: anywhere !important;
  word-break: normal !important;
}
body:not(.reader-image-only) > *,
.main, body > section, body > article, figure, table, pre {
  box-sizing: border-box !important;
  max-width: 100% !important;
  max-inline-size: 100% !important;
}
pre { white-space: pre-wrap !important; overflow-wrap: anywhere !important; }
table { width: 100% !important; table-layout: fixed !important; }
body:not(.reader-image-only) .reader-visual-block {
  box-sizing: border-box !important;
  width: 100% !important;
  height: calc(100vh - (var(--reader-block-padding) * 2)) !important;
  max-width: 100% !important;
  max-height: calc(100vh - (var(--reader-block-padding) * 2)) !important;
  padding: 0 !important; margin: 0 !important;
  display: flex !important; align-items: center !important; justify-content: center !important;
  break-inside: avoid-column !important;
  break-after: column !important;
  -webkit-column-break-inside: avoid !important;
  -webkit-column-break-after: always !important;
}
body:not(.reader-image-only) .reader-visual-block img,
body:not(.reader-image-only) .reader-visual-block svg {
  max-width: 100% !important; max-height: 100% !important;
}
p[style*="opacity"], .wenku-jp { opacity: var(--reader-japanese-opacity) !important; font-family: "Yu Mincho", "Hiragino Mincho ProN", "Noto Serif CJK JP", serif !important; font-size: .94em; }
.wenku-pair-first { margin: 1.2em 0 .3em !important; }
.wenku-pair-second { margin: .3em 0 1.2em !important; }
ruby { ruby-position: over; } rt { font-size: .52em; font-family: "Yu Gothic", "Hiragino Kaku Gothic ProN", sans-serif; }
.tcy { text-combine-upright: all; -webkit-text-combine: horizontal; }
img, svg { display: block; max-width: 100% !important; max-height: calc(100vh - (var(--reader-block-padding) * 2)) !important; width: auto !important; height: auto !important; object-fit: contain; margin: 0 auto !important; break-inside: avoid; }
body.reader-image-only {
  box-sizing: border-box !important;
  width: 100vw !important; height: 100vh !important;
  padding: var(--reader-block-padding) var(--reader-inline-padding) !important;
  display: flex !important; align-items: center !important; justify-content: center !important;
  column-width: auto !important; column-gap: 0 !important;
  overflow: hidden !important;
}
body.reader-image-only > :not(script), body.reader-image-only .main,
body.reader-image-only p {
  box-sizing: border-box !important;
  width: 100% !important; height: 100% !important;
  max-width: 100% !important; max-height: 100% !important;
  padding: 0 !important; margin: 0 !important;
  display: flex !important; align-items: center !important; justify-content: center !important;
}
body.reader-image-only img, body.reader-image-only svg {
  max-width: 100% !important; max-height: 100% !important;
}
a { color: inherit; }
''';
}

String _cssForStyleElement(String css) =>
    css.replaceAll(RegExp(r'</style', caseSensitive: false), r'<\/style');

String _readerScript({required bool japaneseFirst}) {
  final originalIsFirst = japaneseFirst ? 'true' : 'false';
  return '''
<script>
(() => {
  const originalIsFirst = $originalIsFirst;
  const root = document.scrollingElement || document.documentElement;
  const current = () => window.scrollX;
  // Match mature EPUB engines: the viewport is the fixed pagination delta,
  // content length is divided into complete logical pages, and every move is
  // snapped to an integer multiple of that delta.
  const pageDelta = () => Math.max(1, window.innerWidth);
  const contentLength = () => root.scrollWidth;
  const pageCount = () => Math.max(1, Math.ceil(contentLength() / pageDelta()));
  const lastPageIndex = () => pageCount() - 1;
  const clampPage = page => Math.max(0, Math.min(lastPageIndex(), page));
  const pageAtOffset = offset => clampPage(Math.floor(Math.max(0, offset) / pageDelta()));
  let logicalPage = 0;
  let layoutReady = false;
  let pendingLocation = {fraction: 0};
  let extentGuard = null;
  const pageIndex = () => clampPage(logicalPage);
  const clearPageExtent = () => {
    extentGuard?.remove();
    extentGuard = null;
    root.style.removeProperty('min-width');
  };
  const normalizePageExtent = () => {
    clearPageExtent();
    const normalizedWidth = Math.ceil(root.scrollWidth / pageDelta()) * pageDelta();
    // WKWebView can omit the final half-column gap from scrollWidth and does
    // not consistently count a root min-width as scrollable content. An
    // out-of-flow endpoint gives the document the same exact view width that
    // a mature EPUB manager assigns to its section container.
    extentGuard = document.createElement('span');
    extentGuard.setAttribute('aria-hidden', 'true');
    extentGuard.style.cssText = [
      'position:absolute!important',
      'left:' + (normalizedWidth - 1) + 'px!important',
      'top:0!important',
      'width:1px!important',
      'height:1px!important',
      'overflow:hidden!important',
      'opacity:0!important',
      'pointer-events:none!important'
    ].join(';');
    document.body.appendChild(extentGuard);
  };
  const metrics = () => {
    const last = lastPageIndex();
    const page = pageIndex();
    return {ready: layoutReady, fraction: last <= 0 ? 0 : page / last, page, pageCount: last + 1};
  };
  const report = () => {
    if (layoutReady) ReaderBridge.postMessage(JSON.stringify(metrics()));
  };
  const scrollToPage = (page, smooth = true) => window.scrollTo({
    left: clampPage(page) * pageDelta(),
    top: 0,
    behavior: smooth ? 'smooth' : 'auto'
  });
  const moveToPage = (page, smooth = true) => {
    logicalPage = clampPage(page);
    scrollToPage(logicalPage, smooth);
  };
  const sendAction = action => ReaderBridge.postMessage(JSON.stringify({action}));
  window.readerSetAppearance = (background, foreground, originalOpacity) => {
    root.style.setProperty('--reader-background', String(background));
    root.style.setProperty('--reader-foreground', String(foreground));
    root.style.setProperty(
      '--reader-japanese-opacity',
      String(Math.max(.35, Math.min(1, Number(originalOpacity) || .68)))
    );
  };
  const applyPendingLocation = () => {
    if (!layoutReady || !pendingLocation) return;
    const location = pendingLocation;
    pendingLocation = null;
    if (location.fragment) {
      const target = document.getElementById(location.fragment);
      const targetOffset = target
        ? current() + target.getBoundingClientRect().left
        : current();
      logicalPage = pageAtOffset(targetOffset);
      moveToPage(logicalPage, false);
    } else {
      // This is the same resource-progression model used by Readium locators.
      // A progression of 1 resolves to the final logical page, never the raw
      // end of scrollWidth and never the start of the previous resource.
      const normalized = Math.max(0, Math.min(1, Number(location.fraction) || 0));
      moveToPage(Math.floor(normalized * lastPageIndex()), false);
    }
    report();
  };
  window.readerSetFraction = fraction => {
    pendingLocation = {fraction};
    applyPendingLocation();
  };
  window.readerSetFragment = fragment => {
    pendingLocation = {fragment};
    applyPendingLocation();
  };
  window.readerNext = () => {
    const page = pageIndex();
    if (page >= lastPageIndex()) return 'boundary';
    moveToPage(page + 1);
    return 'within';
  };
  window.readerPrevious = () => {
    const page = pageIndex();
    if (page <= 0) return 'boundary';
    moveToPage(page - 1);
    return 'within';
  };
  window.readerSnapToCurrentPage = () => {
    logicalPage = pageAtOffset(current());
    moveToPage(logicalPage, false);
  };
  window.readerProgress = () => JSON.stringify(metrics());
  window.addEventListener('keydown', event => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    const target = event.target;
    if (target?.isContentEditable || /^(INPUT|TEXTAREA|SELECT)/.test(target?.tagName || '')) return;
    const action = event.key === 'ArrowLeft'
      ? 'previous'
      : event.key === 'ArrowRight'
        ? 'next'
        : null;
    if (!action) return;
    event.preventDefault();
    sendAction(action);
  });
  document.querySelectorAll('p[style*="opacity"]').forEach(original => {
    original.classList.add('wenku-jp', originalIsFirst ? 'wenku-pair-first' : 'wenku-pair-second');
    const translation = originalIsFirst ? original.nextElementSibling : original.previousElementSibling;
    if (translation?.tagName === 'P') {
      translation.classList.add('wenku-zh', originalIsFirst ? 'wenku-pair-second' : 'wenku-pair-first');
    }
  });
  let timer;
  window.addEventListener('scroll', () => {
    clearTimeout(timer);
    timer = setTimeout(report, 80);
  }, {passive: true});

  // EPUB engines wait for replaced elements and fonts before restoring a
  // locator. Otherwise an image or font can add columns after a chapter was
  // positioned, which makes "previous chapter" land at its first page.
  const imageReady = image => {
    if (image.complete) {
      return typeof image.decode === 'function' ? image.decode().catch(() => {}) : Promise.resolve();
    }
    return new Promise(resolve => {
      image.addEventListener('load', resolve, {once: true});
      image.addEventListener('error', resolve, {once: true});
    });
  };
  const fontReady = Promise.resolve(document.fonts?.ready).catch(() => {});
  Promise.all([fontReady, ...Array.from(document.images, imageReady)])
    .then(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    .then(() => {
      normalizePageExtent();
      layoutReady = true;
      applyPendingLocation();
      if (pendingLocation === null) report();
    });
  let resizeTimer;
  window.addEventListener('resize', () => {
    if (!layoutReady) return;
    const progression = metrics().fraction;
    layoutReady = false;
    clearPageExtent();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      requestAnimationFrame(() => requestAnimationFrame(() => {
        normalizePageExtent();
        logicalPage = Math.floor(progression * lastPageIndex());
        layoutReady = true;
        moveToPage(logicalPage, false);
        report();
      }));
    }, 100);
  }, {passive: true});
  let pointerStart = null;
  let suppressClickUntil = 0;
  document.addEventListener('pointerdown', event => {
    if (!event.isPrimary) return;
    pointerStart = {x: event.clientX, y: event.clientY, dragging: false};
  }, {passive: true});
  document.addEventListener('pointermove', event => {
    if (!pointerStart) return;
    const dx = event.clientX - pointerStart.x;
    const dy = event.clientY - pointerStart.y;
    if (Math.abs(dx) > 12 && Math.abs(dx) > Math.abs(dy)) {
      pointerStart.dragging = true;
      event.preventDefault();
      window.getSelection()?.removeAllRanges();
    }
  }, {passive: false});
  document.addEventListener('pointerup', event => {
    if (!pointerStart) return;
    const start = pointerStart;
    pointerStart = null;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (start.dragging && Math.abs(dx) >= Math.max(48, window.innerWidth * .07) && Math.abs(dx) > Math.abs(dy) * 1.2) {
      suppressClickUntil = Date.now() + 400;
      sendAction(dx < 0 ? 'next' : 'previous');
    }
  }, {passive: true});
  document.addEventListener('pointercancel', () => { pointerStart = null; }, {passive: true});
  document.addEventListener('click', event => {
    event.preventDefault();
    if (Date.now() < suppressClickUntil || window.getSelection()?.toString()) return;
    const ratio = event.clientX / Math.max(1, window.innerWidth);
    if (ratio < .36) sendAction('previous');
    else if (ratio > .64) sendAction('next');
    else ReaderBridge.postMessage(JSON.stringify({tap: true}));
  }, true);
  let wheelDistance = 0;
  let wheelReset;
  let wheelCooldownUntil = 0;
  document.addEventListener('wheel', event => {
    if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return;
    event.preventDefault();
    if (Date.now() < wheelCooldownUntil) return;
    wheelDistance += event.deltaX;
    clearTimeout(wheelReset);
    wheelReset = setTimeout(() => { wheelDistance = 0; }, 180);
    if (Math.abs(wheelDistance) >= 48) {
      sendAction(wheelDistance > 0 ? 'next' : 'previous');
      wheelDistance = 0;
      wheelCooldownUntil = Date.now() + 450;
    }
  }, {passive: false});
})();
</script>
''';
}
