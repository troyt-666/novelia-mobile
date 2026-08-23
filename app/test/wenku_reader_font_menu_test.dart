import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/wenku/wenku_reader_screen.dart';

void main() {
  testWidgets('font-size overlay dismisses when outside is tapped', (
    tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WenkuReaderFontSizeOverlay(
            currentFontSize: 18,
            onDismiss: () => dismissed = true,
            onSelected: (_) {},
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
          body: WenkuReaderFontSizeOverlay(
            currentFontSize: 18,
            onDismiss: () {},
            onSelected: (value) => selected = value,
          ),
        ),
      ),
    );

    await tester.tap(find.text('大字号'));

    expect(selected, 22);
  });
}
