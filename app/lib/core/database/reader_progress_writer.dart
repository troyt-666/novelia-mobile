import 'dart:async';

import 'local_state_repository.dart';

/// Coalesces rapid reader stops without allowing continuous input to postpone
/// persistence indefinitely. Lifecycle/exit callers flush synchronously.
class ReaderProgressWriter {
  ReaderProgressWriter({
    required this.savePosition,
    required this.saveExitPosition,
    required this.onError,
    this.idleDelay = const Duration(milliseconds: 500),
    this.maximumDelay = const Duration(seconds: 2),
  });

  final void Function(LocalReadingProgress) savePosition;
  final void Function(LocalReadingProgress) saveExitPosition;
  final void Function(Object, StackTrace) onError;
  final Duration idleDelay;
  final Duration maximumDelay;
  LocalReadingProgress? _pending;
  bool _pendingIsExit = false;
  Timer? _idle;
  Timer? _deadline;

  void schedule(LocalReadingProgress progress) {
    if (_pending != null && _pending!.novelId != progress.novelId) flush();
    _pending = progress;
    _pendingIsExit = false;
    _idle?.cancel();
    _idle = Timer(idleDelay, _flushTimer);
    _deadline ??= Timer(maximumDelay, _flushTimer);
  }

  void _cancelTimers() {
    _idle?.cancel();
    _deadline?.cancel();
    _idle = null;
    _deadline = null;
  }

  void _flushTimer() {
    try {
      flush();
    } catch (error, stack) {
      // Retain the latest position for the next stop or lifecycle flush.
      onError(error, stack);
    }
  }

  void flush() {
    _cancelTimers();
    final pending = _pending;
    if (pending == null) return;
    if (_pendingIsExit) {
      saveExitPosition(pending);
    } else {
      savePosition(pending);
    }
    _pending = null;
  }

  void saveNow(LocalReadingProgress progress) {
    if (_pending != null && _pending!.novelId != progress.novelId) flush();
    _pending = progress;
    _pendingIsExit = false;
    flush();
  }

  void finish(LocalReadingProgress progress) {
    if (_pending != null && _pending!.novelId != progress.novelId) flush();
    // No delayed reader-route write may run after navigation back to the shelf.
    _pending = progress;
    _pendingIsExit = true;
    flush();
  }

  void dispose() => flush();
}
