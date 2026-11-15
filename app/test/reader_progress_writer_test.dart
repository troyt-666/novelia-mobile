import 'package:flutter_test/flutter_test.dart';
import 'package:jfzreader/core/database/local_state_repository.dart';
import 'package:jfzreader/core/database/reader_progress_writer.dart';
import 'package:jfzreader/core/model/reader_models.dart';

LocalReadingProgress position(int block, {String novel = 'novel'}) =>
    LocalReadingProgress(
      novelId: novel,
      position: ReadingPosition(chapterId: 'c1', blockId: 'c1:$block'),
      updatedAt: DateTime.utc(2026).add(Duration(seconds: block)),
    );

void main() {
  testWidgets('eight rapid stops save the latest position once', (
    tester,
  ) async {
    final writes = <LocalReadingProgress>[];
    final writer = ReaderProgressWriter(
      savePosition: writes.add,
      saveExitPosition: writes.add,
      onError: (error, _) => fail('$error'),
    );
    addTearDown(writer.dispose);
    for (var i = 0; i < 8; i++) {
      writer.schedule(position(i));
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(writes, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(writes.map((p) => p.position.blockId), ['c1:7']);
  });

  testWidgets('continuous input cannot postpone a save past two seconds', (
    tester,
  ) async {
    final writes = <LocalReadingProgress>[];
    final writer = ReaderProgressWriter(
      savePosition: writes.add,
      saveExitPosition: writes.add,
      onError: (error, _) => fail('$error'),
    );
    addTearDown(writer.dispose);
    for (var i = 0; i < 10; i++) {
      writer.schedule(position(i));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(writes.map((p) => p.position.blockId), ['c1:9']);
    writer.schedule(position(10));
    writer.flush();
    expect(writes.last.position.blockId, 'c1:10');
    await tester.pump(const Duration(seconds: 3));
    expect(writes, hasLength(2));
  });

  testWidgets(
    'exit replaces a pending stop and cancels delayed reader routes',
    (tester) async {
      final reader = <LocalReadingProgress>[];
      final exits = <LocalReadingProgress>[];
      final writer = ReaderProgressWriter(
        savePosition: reader.add,
        saveExitPosition: exits.add,
        onError: (error, _) => fail('$error'),
      );
      addTearDown(writer.dispose);
      writer.schedule(position(4));
      writer.finish(position(3)); // Backward reading must also win.
      expect(exits.single.position.blockId, 'c1:3');
      await tester.pump(const Duration(seconds: 3));
      expect(reader, isEmpty);
      expect(exits, hasLength(1));
    },
  );

  testWidgets('switching books preserves both books and flush is idempotent', (
    tester,
  ) async {
    final writes = <LocalReadingProgress>[];
    final writer = ReaderProgressWriter(
      savePosition: writes.add,
      saveExitPosition: writes.add,
      onError: (error, _) => fail('$error'),
    );
    writer.schedule(position(1, novel: 'a'));
    writer.schedule(position(2, novel: 'b'));
    expect(writes.map((p) => p.novelId), ['a']);
    writer.dispose();
    writer.flush();
    expect(writes.map((p) => p.novelId), ['a', 'b']);
    await tester.pump(const Duration(seconds: 3));
    expect(writes, hasLength(2));
  });

  testWidgets(
    'a failed timer retains the latest position for a lifecycle retry',
    (tester) async {
      var shouldFail = true;
      var errors = 0;
      final writes = <LocalReadingProgress>[];
      final writer = ReaderProgressWriter(
        savePosition: (p) {
          if (shouldFail) throw StateError('fixture disk error');
          writes.add(p);
        },
        saveExitPosition: writes.add,
        onError: (_, _) {
          errors++;
        },
      );
      writer.schedule(position(5));
      await tester.pump(const Duration(milliseconds: 600));
      expect(errors, 1);
      expect(writes, isEmpty);
      shouldFail = false;
      writer.flush();
      expect(writes.single.position.blockId, 'c1:5');
      writer.dispose();
    },
  );

  testWidgets('failed exit retries without restoring the reader route', (
    tester,
  ) async {
    var shouldFail = true;
    final reader = <LocalReadingProgress>[];
    final exits = <LocalReadingProgress>[];
    final writer = ReaderProgressWriter(
      savePosition: reader.add,
      saveExitPosition: (p) {
        if (shouldFail) throw StateError('fixture disk error');
        exits.add(p);
      },
      onError: (error, _) => fail('$error'),
    );
    writer.schedule(position(5));
    expect(() => writer.finish(position(6)), throwsStateError);
    shouldFail = false;
    writer.flush();
    expect(exits.single.position.blockId, 'c1:6');
    expect(reader, isEmpty);
    writer.dispose();
  });
}
