import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../gateway/novelia/novelia_gateway.dart';
import '../../gateway/novelia/novelia_wenku_gateway.dart';
import 'wenku_epub_document.dart';

class WenkuReaderScreen extends StatefulWidget {
  const WenkuReaderScreen({
    required this.epubBytes,
    required this.title,
    required this.order,
    super.key,
  });

  final Uint8List epubBytes;
  final String title;
  final WenkuBilingualOrder order;

  @override
  State<WenkuReaderScreen> createState() => _WenkuReaderScreenState();
}

class _WenkuReaderScreenState extends State<WenkuReaderScreen> {
  WebViewController? _controller;
  WenkuEpubDocument? _document;
  Object? _failure;
  String? _failureDetails;
  var _generation = 0;
  var _spineIndex = 0;
  var _localFraction = 0.0;
  var _overallProgress = 0.0;
  var _fontSize = 18.0;
  var _loading = true;
  var _controlsVisible = true;
  var _fontMenuVisible = false;
  var _turningPage = false;
  String? _pendingFragment;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  void _initialize() {
    final generation = ++_generation;
    setState(() {
      _failure = null;
      _failureDetails = null;
      _loading = true;
    });
    try {
      final document = WenkuEpubDocument.parse(widget.epubBytes);
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(
          'ReaderBridge',
          onMessageReceived: _onReaderMessage,
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              final uri = Uri.tryParse(request.url);
              return uri == null ||
                      uri.scheme == 'about' ||
                      uri.scheme == 'data'
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
            onPageFinished: (_) {
              if (generation == _generation) _restoreWithinSpine();
            },
            onWebResourceError: (error) {
              // WebKit reports a cancelled provisional navigation as -999
              // when loadHtmlString replaces about:blank. The replacement
              // page still completes and must not become a reader failure.
              if (error.errorCode == -999 ||
                  error.isForMainFrame != true ||
                  generation != _generation) {
                return;
              }
              _showFailure(
                StateError(error.description),
                details: '${error.description} (${error.errorCode})',
              );
            },
          ),
        );
      setState(() {
        _document = document;
        _controller = controller;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadSpine();
      });
    } on Object catch (error) {
      _showFailure(error);
    }
  }

  void _showFailure(Object error, {String? details}) {
    if (!mounted) return;
    setState(() {
      _failure = error;
      _failureDetails = details ?? _failureMessage(error);
      _loading = false;
    });
  }

  void _onReaderMessage(JavaScriptMessage message) {
    try {
      final value = jsonDecode(message.message);
      if (value is! Map) return;
      final action = value['action'];
      if (action == 'next') {
        unawaited(_next());
        return;
      }
      if (action == 'previous') {
        unawaited(_previous());
        return;
      }
      if (value['tap'] == true) {
        if (mounted) {
          setState(() {
            _controlsVisible = !_controlsVisible;
            _fontMenuVisible = false;
          });
        }
        return;
      }
      if (value['ready'] == true && mounted && _loading) {
        setState(() => _loading = false);
      }
      if (value['fraction'] is! num) return;
      final fraction = (value['fraction'] as num)
          .toDouble()
          .clamp(0, 1)
          .toDouble();
      final length = _document?.spineLength ?? 1;
      if (!mounted) return;
      setState(() {
        _localFraction = fraction;
        _overallProgress = ((_spineIndex + fraction) / length)
            .clamp(0, 1)
            .toDouble();
      });
    } on FormatException {
      // Ignore malformed messages from the isolated document host.
    }
  }

  Future<void> _loadSpine({double fraction = 0, String? fragment}) async {
    final controller = _controller;
    final document = _document;
    if (controller == null || document == null) return;
    setState(() {
      _loading = true;
      _failure = null;
      _localFraction = fraction.clamp(0, 1);
      _pendingFragment = fragment;
    });
    try {
      final html = document.htmlForSpine(
        _spineIndex,
        dark: Theme.of(context).brightness == Brightness.dark,
        fontSize: _fontSize,
        japaneseFirst: widget.order == WenkuBilingualOrder.japaneseFirst,
      );
      await controller.loadHtmlString(html);
    } on Object catch (error) {
      _showFailure(error);
    }
  }

  Future<void> _restoreWithinSpine() async {
    final controller = _controller;
    if (controller == null) return;
    final fragment = _pendingFragment;
    if (fragment != null) {
      await controller.runJavaScript(
        'readerSetFragment(${jsonEncode(fragment)});',
      );
      _pendingFragment = null;
    } else {
      await controller.runJavaScript('readerSetFraction($_localFraction);');
    }
  }

  Future<void> _next() async {
    if (_turningPage) return;
    final controller = _controller;
    final document = _document;
    if (controller == null || document == null) return;
    _turningPage = true;
    try {
      final result = await controller.runJavaScriptReturningResult(
        'readerNext();',
      );
      if (_jsString(result) != 'boundary') return;
      if (_spineIndex + 1 >= document.spineLength) return;
      setState(() => _spineIndex += 1);
      await _loadSpine();
    } finally {
      _turningPage = false;
    }
  }

  Future<void> _previous() async {
    if (_turningPage) return;
    final controller = _controller;
    if (controller == null) return;
    _turningPage = true;
    try {
      final result = await controller.runJavaScriptReturningResult(
        'readerPrevious();',
      );
      if (_jsString(result) != 'boundary' || _spineIndex <= 0) return;
      setState(() => _spineIndex -= 1);
      await _loadSpine(fraction: 1);
    } finally {
      _turningPage = false;
    }
  }

  static String _jsString(Object value) {
    final text = value.toString();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      return text.substring(1, text.length - 1);
    }
    return text;
  }

  void _showContents() {
    final document = _document;
    if (document == null) return;
    setState(() => _fontMenuVisible = false);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            for (final entry in document.toc)
              ListTile(
                title: Text(entry.title),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _spineIndex = entry.spineIndex);
                  _loadSpine(fragment: entry.fragment);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _setFontSize(double fontSize) async {
    setState(() {
      _fontSize = fontSize;
      _fontMenuVisible = false;
    });
    await _loadSpine(fraction: _localFraction);
  }

  Future<void> _seek(double value) async {
    final document = _document;
    if (document == null) return;
    final scaled = value.clamp(0, 0.999999) * document.spineLength;
    final index = scaled.floor().clamp(0, document.spineLength - 1);
    final fraction = (scaled - index).toDouble();
    setState(() {
      _overallProgress = value;
      _spineIndex = index;
    });
    await _loadSpine(fraction: fraction);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_failure != null)
            Positioned.fill(
              child: _ReaderFailure(
                details: _failureDetails,
                onRetry: _initialize,
              ),
            )
          else ...[
            if (_controller != null)
              Positioned.fill(child: WebViewWidget(controller: _controller!)),
            if (_loading)
              Positioned.fill(
                child: ColoredBox(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xff171613)
                      : const Color(0xfffbf8f1),
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: SafeArea(
                  bottom: false,
                  child: Material(
                    color: colors.surfaceContainer.withValues(alpha: .96),
                    child: SizedBox(
                      height: 64,
                      child: Row(
                        children: [
                          const BackButton(),
                          Expanded(
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: '目录',
                            onPressed: _showContents,
                            icon: const Icon(Icons.toc),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_failure == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: SafeArea(
                    top: false,
                    child: Material(
                      color: colors.surfaceContainer.withValues(alpha: .96),
                      child: SizedBox(
                        height: 64,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Slider(
                                  value: _overallProgress,
                                  onChanged: (value) =>
                                      setState(() => _overallProgress = value),
                                  onChangeEnd: _seek,
                                ),
                              ),
                              Text('${(_overallProgress * 100).round()}%'),
                              IconButton(
                                tooltip: '字号',
                                onPressed: () => setState(
                                  () => _fontMenuVisible = !_fontMenuVisible,
                                ),
                                icon: const Icon(Icons.text_fields),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_fontMenuVisible && _failure == null)
            Positioned.fill(
              child: WenkuReaderFontSizeOverlay(
                currentFontSize: _fontSize,
                onDismiss: () => setState(() => _fontMenuVisible = false),
                onSelected: _setFontSize,
              ),
            ),
        ],
      ),
    );
  }
}

@visibleForTesting
class WenkuReaderFontSizeOverlay extends StatelessWidget {
  const WenkuReaderFontSizeOverlay({
    required this.currentFontSize,
    required this.onDismiss,
    required this.onSelected,
    super.key,
  });

  final double currentFontSize;
  final VoidCallback onDismiss;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            button: true,
            label: '关闭字号菜单',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Positioned(
          right: 12,
          bottom: MediaQuery.paddingOf(context).bottom + 72,
          child: Material(
            elevation: 8,
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: 168,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final option in const <(double, String)>[
                    (15, '小字号'),
                    (18, '标准字号'),
                    (22, '大字号'),
                    (26, '特大字号'),
                  ])
                    ListTile(
                      dense: true,
                      leading: Icon(
                        currentFontSize == option.$1
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 20,
                      ),
                      title: Text(option.$2),
                      onTap: () => onSelected(option.$1),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _failureMessage(Object error) {
  if (error is NoveliaGatewayException) return error.message;
  return '$error';
}

class _ReaderFailure extends StatelessWidget {
  const _ReaderFailure({required this.onRetry, this.details});

  final VoidCallback onRetry;
  final String? details;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image_outlined, size: 42),
        const SizedBox(height: 12),
        const Text('EPUB 载入失败'),
        if (details != null && details!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SelectableText(
              details!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        const SizedBox(height: 14),
        FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}
