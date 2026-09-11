import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Receives native volume key events only while the reader is active.
class ReaderVolumeKeys extends StatefulWidget {
  const ReaderVolumeKeys({
    required this.onPrevious,
    required this.onNext,
    required this.child,
    this.enabled = true,
    super.key,
  });

  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Widget child;
  final bool enabled;

  @override
  State<ReaderVolumeKeys> createState() => _ReaderVolumeKeysState();
}

class _ReaderVolumeKeysState extends State<ReaderVolumeKeys>
    with WidgetsBindingObserver {
  static final _events = const EventChannel(
    'io.github.troyt666.jfzreader/reader_volume_keys',
  ).receiveBroadcastStream();
  StreamSubscription<dynamic>? _subscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool get _active {
    // The standard Flutter SDK does not declare TargetPlatform.ohos.
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform.name != 'ohos') ||
        !widget.enabled ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return false;
    }
    return true;
  }

  void _syncSubscription() {
    if (_active) {
      _subscription ??= _events.listen((direction) {
        if (!mounted || !_active) return;
        if (direction == -1) widget.onPrevious();
        if (direction == 1) widget.onNext();
      });
    } else {
      unawaited(_subscription?.cancel());
      _subscription = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSubscription();
  }

  @override
  void didUpdateWidget(ReaderVolumeKeys oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSubscription();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _syncSubscription();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
