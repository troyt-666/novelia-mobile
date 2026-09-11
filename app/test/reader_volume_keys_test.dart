import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/reader/reader_volume_keys.dart';

void main() {
  testWidgets('volume keys turn once per press only in the active reader', (
    tester,
  ) async {
    var previous = 0;
    var next = 0;
    var enabled = true;
    final navigator = GlobalKey<NavigatorState>();
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return ReaderVolumeKeys(
              enabled: enabled,
              onPrevious: () => previous++,
              onNext: () => next++,
              child: const Scaffold(body: TextField(autofocus: true)),
            );
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      await tester.sendKeyDownEvent(LogicalKeyboardKey.audioVolumeDown),
      isTrue,
    );
    expect(
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.audioVolumeDown),
      isTrue,
    );
    expect(
      await tester.sendKeyUpEvent(LogicalKeyboardKey.audioVolumeDown),
      isTrue,
    );
    expect(next, 1);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp), isTrue);
    expect(previous, 1);

    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Another screen')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown),
      isFalse,
    );
    expect(next, 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown),
      isTrue,
    );
    expect(next, 2);

    update(() => enabled = false);
    await tester.pump();
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown),
      isFalse,
    );
    expect(next, 2);
    update(() => enabled = true);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown),
      isFalse,
    );
    expect(next, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown),
      isFalse,
    );
    expect(next, 2);
    debugDefaultTargetPlatformOverride = null;

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown),
      isFalse,
    );
    expect(next, 2);
  });
}
