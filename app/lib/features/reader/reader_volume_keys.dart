import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Handles Android volume keys even when the reader's WebView has focus.
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

class _ReaderVolumeKeysState extends State<ReaderVolumeKeys> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        !widget.enabled ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return false;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.audioVolumeUp &&
        key != LogicalKeyboardKey.audioVolumeDown) {
      return false;
    }
    // Consume releases and repeats too, so Android does not change volume.
    if (event is KeyDownEvent && !event.synthesized) {
      (key == LogicalKeyboardKey.audioVolumeUp
              ? widget.onPrevious
              : widget.onNext)
          .call();
    }
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
