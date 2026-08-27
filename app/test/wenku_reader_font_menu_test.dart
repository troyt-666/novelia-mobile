import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/wenku/wenku_epub_document.dart';
import 'package:jfzreader/features/wenku/wenku_reader_screen.dart';

void main() {
  testWidgets('font-size overlay dismisses when outside is tapped', (
    tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WenkuReaderSettingsOverlay(
            currentFontSize: 18,
            palette: WenkuEpubPalette.automatic,
            japaneseOpacity: .68,
            onDismiss: () => dismissed = true,
            onFontSizeSelected: (_) {},
            onPaletteSelected: (_) {},
            onJapaneseOpacitySelected: (_) {},
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(20, 20));

    expect(dismissed, isTrue);
  });

  testWidgets('font-size overlay reports a selected size', (tester) async {
    double? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WenkuReaderSettingsOverlay(
            currentFontSize: 18,
            palette: WenkuEpubPalette.automatic,
            japaneseOpacity: .68,
            onDismiss: () {},
            onFontSizeSelected: (value) => selected = value,
            onPaletteSelected: (_) {},
            onJapaneseOpacitySelected: (_) {},
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.text('大字号'));
    await tester.pump();
    await tester.tap(find.text('大字号'));

    expect(selected, 22);
  });

  testWidgets('reader settings report palette and original contrast', (
    tester,
  ) async {
    WenkuEpubPalette? palette;
    double? opacity;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WenkuReaderSettingsOverlay(
            currentFontSize: 18,
            palette: WenkuEpubPalette.automatic,
            japaneseOpacity: .68,
            onDismiss: () {},
            onFontSizeSelected: (_) {},
            onPaletteSelected: (value) => palette = value,
            onJapaneseOpacitySelected: (value) => opacity = value,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('wenku-reader-palette-sepia')));
    await tester.tap(find.text('清晰'));

    expect(palette, WenkuEpubPalette.sepia);
    expect(opacity, .9);
  });

  testWidgets('reader settings fit a narrow resized pane', (tester) async {
    tester.view.physicalSize = const Size(280, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WenkuReaderSettingsOverlay(
            currentFontSize: 18,
            palette: WenkuEpubPalette.automatic,
            japaneseOpacity: .68,
            onDismiss: () {},
            onFontSizeSelected: (_) {},
            onPaletteSelected: (_) {},
            onJapaneseOpacitySelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('阅读设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('eye-care palette uses a green background with dark readable text', () {
    final colors = WenkuEpubPalette.eyeCare.resolve(systemDark: false);

    expect(colors.background, '#dce8d2');
    expect(colors.foreground, '#263126');
    expect(WenkuEpubPalette.eyeCare.label, '护眼');
  });

  test('Wenku keyboard navigation uses horizontal arrows only', () {
    expect(wenkuReaderActionForKey(LogicalKeyboardKey.arrowLeft), 'previous');
    expect(wenkuReaderActionForKey(LogicalKeyboardKey.arrowRight), 'next');
    expect(wenkuReaderActionForKey(LogicalKeyboardKey.arrowUp), isNull);
    expect(wenkuReaderActionForKey(LogicalKeyboardKey.arrowDown), isNull);
  });
}
