import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/features/reader/reader_volume_keys.dart';

void main() {
  for (final platform in TargetPlatform.values.where(
    (platform) => platform == TargetPlatform.android || platform.name == 'ohos',
  )) {
    testWidgets('${platform.name} volume keys reach only the active reader', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel(
        'io.github.troyt666.jfzreader/reader_volume_keys',
      );
      var listening = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        listening = call.method == 'listen';
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      Future<void> press(int direction) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeSuccessEnvelope(direction),
          (_) {},
        );
        await tester.pump();
      }

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

      expect(listening, isTrue);
      await press(1);
      expect(next, 1);
      await press(-1);
      expect(previous, 1);
      await press(99);
      expect(next, 1);
      expect(previous, 1);

      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Another screen')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(listening, isFalse);
      expect(next, 1);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(listening, isTrue);
      await press(1);
      expect(next, 2);

      update(() => enabled = false);
      await tester.pump();
      expect(listening, isFalse);
      expect(next, 2);
      update(() => enabled = true);
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(listening, isFalse);
      expect(next, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(listening, isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      update(() {});
      await tester.pump();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(listening, isFalse);
      expect(next, 2);
      debugDefaultTargetPlatformOverride = null;

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(listening, isFalse);
      expect(next, 2);
    });
  }
}
