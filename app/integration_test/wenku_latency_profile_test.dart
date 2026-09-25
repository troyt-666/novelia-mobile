import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jfzreader/features/wenku/wenku_epub_document.dart';
import 'package:jfzreader/features/wenku/wenku_epub_store.dart';
import 'package:jfzreader/features/wenku/wenku_reader_screen.dart';
import 'package:jfzreader/gateway/novelia/novelia_wenku_gateway.dart';
import 'package:webview_flutter/webview_flutter.dart';

// Measures the production Flutter <-> native WebView path. Input begins at a
// DOM click, so these timings exclude OS pointer delivery and display scanout.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'profile EPUB edge taps in the native reader',
    (tester) async {
      expect(kProfileMode, isTrue, reason: 'Run with flutter drive --profile.');
      final directory = await Directory.systemTemp.createTemp('wenku-profile-');
      final store = WenkuEpubStore(rootDirectory: () async => directory);
      const request = WenkuEpubRequest(
        novelId: 'latency-fixture',
        volumeId: 'one',
        order: WenkuBilingualOrder.chineseFirst,
        providers: [WenkuTranslationProvider.sakura],
        filename: 'latency.epub',
      );
      final bytes = _epub();
      await store.save(request, bytes, title: 'EPUB 性能样本');
      final document = WenkuEpubDocument.parse(bytes);
      final report = <String, dynamic>{};
      binding.reportData = report;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await directory.delete(recursive: true);
      });

      for (final persist in [false, true]) {
        final writes = <double>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 430,
                height: 720,
                child: WenkuReaderScreen(
                  key: ValueKey(persist),
                  document: document,
                  title: 'EPUB 性能样本',
                  order: WenkuBilingualOrder.chineseFirst,
                  onPositionChanged: persist
                      ? (position) async {
                          final watch = Stopwatch()..start();
                          await store.saveReadingPosition(
                            store.fileNameForRequest(request),
                            position,
                          );
                          writes.add(watch.elapsedMicroseconds / 1000);
                        }
                      : null,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final controller = tester
            .widget<WebViewWidget>(find.byType(WebViewWidget))
            .platform
            .params
            .controller;
        Future<Object> js(String source) =>
            controller.runJavaScriptReturningResult(source);
        Future<void> waitFor(String expression) async {
          for (var i = 0; i < 250; i++) {
            if ((await js(expression)).toString() == 'true') return;
            await tester.pump(const Duration(milliseconds: 20));
          }
          fail('WebView did not reach: $expression');
        }

        await waitFor(
          'typeof readerProgress === "function" && JSON.parse(readerProgress()).ready',
        );
        await tester.pumpAndSettle();
        await controller.runJavaScript(_instrumentation);
        report['viewport'] = jsonDecode(
          (await js(
            'JSON.stringify({width:innerWidth,height:innerHeight,pages:JSON.parse(readerProgress()).pageCount})',
          )).toString(),
        );
        for (final mode in [
          'bridge_smooth',
          'direct_smooth',
          'bridge_instant',
        ]) {
          final samples = <dynamic>[];
          for (var i = 0; i < 14; i++) {
            await controller.runJavaScript(
              'window.measureTurn(${i.isEven}, ${jsonEncode(mode)});',
            );
            await waitFor(
              'window.turnSample && window.turnSample.done === true',
            );
            final sample = jsonDecode(
              (await js('JSON.stringify(window.turnSample)')).toString(),
            );
            expect(sample['timeout'], isNot(true), reason: '$sample');
            if (i >= 2) samples.add(sample); // warm up in both directions
            await tester.pump(const Duration(milliseconds: 130));
          }
          report['${persist ? "disk" : "no_disk"}_$mode'] = samples;
          debugPrint(
            'EPUB_PROFILE ${persist ? "disk" : "no_disk"}_$mode ${jsonEncode(samples)}',
          );
        }
        await controller.runJavaScript('window.restoreMeasuredScroll();');
        final boundaries = <double>[];
        for (var i = 0; i < 6; i++) {
          final forward = i.isEven;
          await controller.runJavaScript(
            'readerSetFraction(${forward ? 1 : 0});',
          );
          await tester.pump(const Duration(milliseconds: 150));
          final watch = Stopwatch()..start();
          await controller.runJavaScript(
            'document.dispatchEvent(new MouseEvent("click", {clientX: innerWidth * ${forward ? .9 : .1}, clientY: innerHeight / 2, bubbles: true, cancelable: true}));',
          );
          await waitFor(
            'document.querySelector("h1")?.textContent === "性能样本 ${forward ? 1 : 0}" && typeof readerProgress === "function" && JSON.parse(readerProgress()).ready',
          );
          boundaries.add(watch.elapsedMicroseconds / 1000);
          await tester.pumpAndSettle();
        }
        report['${persist ? "disk" : "no_disk"}_spine_ms'] = boundaries;
        report['position_write_ms'] = writes;
        expect(tester.takeException(), isNull);
      }
      debugPrint('EPUB_PROFILE_COMPLETE ${jsonEncode(report)}');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

const _instrumentation = r'''
(() => {
  const originalScroll = window.scrollTo.bind(window);
  window.restoreMeasuredScroll = () => { window.scrollTo = originalScroll; };
  window.measureTurn = (forward, mode) => {
    const start = performance.now();
    const x = scrollX;
    const sample = window.turnSample = {mode, forward, startX:x, done:false};
    let target = x;
    let stable = 0;
    window.scrollTo = options => {
      sample.commandMs = performance.now() - start;
      target = options.left;
      originalScroll({...options, behavior:mode === 'bridge_instant' ? 'auto' : options.behavior});
    };
    const tick = () => {
      const elapsed = performance.now() - start;
      if (Math.abs(scrollX - x) > .5 && sample.firstMovementMs === undefined) sample.firstMovementMs = elapsed;
      if (target !== x && Math.abs(scrollX - target) < 1) {
        if (++stable === 2) { sample.settledMs = elapsed; sample.endX = scrollX; sample.done = true; return; }
      } else stable = 0;
      if (elapsed > 2000) { sample.timeout = true; sample.done = true; return; }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    if (mode === 'direct_smooth') {
      if (forward) readerNext(); else readerPrevious();
    } else {
      document.dispatchEvent(new MouseEvent('click', {clientX:innerWidth * (forward ? .9 : .1), clientY:innerHeight/2, bubbles:true, cancelable:true}));
    }
  };
})();
''';

Uint8List _epub() {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="book/package.opf"/></rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'book/package.opf',
        '''
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>EPUB 性能样本</dc:title></metadata>
<manifest>${List.generate(3, (i) => '<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>').join()}</manifest>
<spine>${List.generate(3, (i) => '<itemref idref="c$i"/>').join()}</spine></package>''',
      ),
    );
  for (var i = 0; i < 3; i++) {
    archive.addFile(
      ArchiveFile.string('book/c$i.xhtml', '''
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>性能样本 $i</title></head><body><h1>性能样本 $i</h1>
${List.generate(180, (j) => '<p>第 $j 段：列车沿着海岸继续前行。少女翻开书页，窗外的灯光落在文字之间。这是一段用于重复测量翻页响应的虚构故事。</p><p style="opacity:0.4;">列車は海岸に沿って進み続ける。少女は本を開いた。窓の外の明かりが文字の間に落ちていた。</p>').join()}
</body></html>'''),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
