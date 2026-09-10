import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../gateway/novelia/novelia_gateway.dart';
import '../../gateway/novelia/novelia_wenku_gateway.dart';
import 'wenku_epub_document.dart';

@visibleForTesting
String? wenkuReaderActionForKey(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowLeft) return 'previous';
  if (key == LogicalKeyboardKey.arrowRight) return 'next';
  return null;
}

class WenkuReaderScreen extends StatefulWidget {
  const WenkuReaderScreen({
    required this.document,
    required this.title,
    required this.order,
    super.key,
  });

  final WenkuEpubDocument document;
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
  var _spineGeneration = 0;
  var _spineIndex = 0;
  var _localFraction = 0.0;
  var _overallProgress = 0.0;
  var _fontSize = 18.0;
  var _palette = WenkuEpubPalette.automatic;
  var _japaneseOpacity = .68;
  var _loading = true;
  var _controlsVisible = true;
  var _fontMenuVisible = false;
  var _turningPage = false;
  Brightness? _lastBrightness;
  String? _pendingFragment;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    final changed = _lastBrightness != null && _lastBrightness != brightness;
    _lastBrightness = brightness;
    if (changed && _palette == WenkuEpubPalette.automatic) {
      unawaited(_applyAppearance());
    }
  }

  void _initialize() {
    final generation = ++_generation;
    _spineGeneration++;
    setState(() {
      _failure = null;
      _failureDetails = null;
      _loading = true;
    });
    try {
      final document = widget.document;
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
    final generation = ++_spineGeneration;
    setState(() {
      _loading = true;
      _failure = null;
      _localFraction = fraction.clamp(0, 1);
      _pendingFragment = fragment;
    });
    try {
      final html = await document.htmlForSpineAsync(
        _spineIndex,
        dark: Theme.of(context).brightness == Brightness.dark,
        fontSize: _fontSize,
        japaneseFirst: widget.order == WenkuBilingualOrder.japaneseFirst,
        palette: _palette,
        japaneseOpacity: _japaneseOpacity,
      );
      if (!mounted || generation != _spineGeneration) return;
      await controller.loadHtmlString(html);
    } on Object catch (error) {
      if (!mounted || generation != _spineGeneration) return;
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

  WenkuEpubColors _resolvedColors() => _palette.resolve(
    systemDark: Theme.of(context).brightness == Brightness.dark,
  );

  Future<void> _applyAppearance() async {
    final controller = _controller;
    if (controller == null) return;
    final colors = _resolvedColors();
    try {
      await controller.runJavaScript(
        'readerSetAppearance('
        '${jsonEncode(colors.background)},'
        '${jsonEncode(colors.foreground)},'
        '$_japaneseOpacity);',
      );
    } on Object {
      // A theme change may race a spine replacement. The next document load
      // receives the same values in its initial CSS.
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final action = wenkuReaderActionForKey(event.logicalKey);
    if (action == null) return KeyEventResult.ignored;
    unawaited(action == 'next' ? _next() : _previous());
    return KeyEventResult.handled;
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

  void _setPalette(WenkuEpubPalette palette) {
    setState(() => _palette = palette);
    unawaited(_applyAppearance());
  }

  void _setJapaneseOpacity(double opacity) {
    setState(() => _japaneseOpacity = opacity);
    unawaited(_applyAppearance());
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
    final readerColors = _resolvedColors();
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: _colorFromHex(readerColors.background),
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
                    color: _colorFromHex(readerColors.background),
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
                                    onChanged: (value) => setState(
                                      () => _overallProgress = value,
                                    ),
                                    onChangeEnd: _seek,
                                  ),
                                ),
                                Text('${(_overallProgress * 100).round()}%'),
                                IconButton(
                                  key: const ValueKey(
                                    'wenku-reader-settings-button',
                                  ),
                                  tooltip: '阅读设置',
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
                child: WenkuReaderSettingsOverlay(
                  currentFontSize: _fontSize,
                  palette: _palette,
                  japaneseOpacity: _japaneseOpacity,
                  onDismiss: () => setState(() => _fontMenuVisible = false),
                  onFontSizeSelected: _setFontSize,
                  onPaletteSelected: _setPalette,
                  onJapaneseOpacitySelected: _setJapaneseOpacity,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
class WenkuReaderSettingsOverlay extends StatelessWidget {
  const WenkuReaderSettingsOverlay({
    required this.currentFontSize,
    required this.palette,
    required this.japaneseOpacity,
    required this.onDismiss,
    required this.onFontSizeSelected,
    required this.onPaletteSelected,
    required this.onJapaneseOpacitySelected,
    super.key,
  });

  final double currentFontSize;
  final WenkuEpubPalette palette;
  final double japaneseOpacity;
  final VoidCallback onDismiss;
  final ValueChanged<double> onFontSizeSelected;
  final ValueChanged<WenkuEpubPalette> onPaletteSelected;
  final ValueChanged<double> onJapaneseOpacitySelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            button: true,
            label: '关闭阅读设置',
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
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .72,
              ),
              child: SizedBox(
                width: (MediaQuery.sizeOf(context).width - 24).clamp(
                  0.0,
                  292.0,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '阅读设置',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 14),
                      Text('背景', style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 7,
                        runSpacing: 4,
                        children: [
                          for (final option in WenkuEpubPalette.values)
                            ChoiceChip(
                              key: ValueKey(
                                'wenku-reader-palette-${option.name}',
                              ),
                              label: Text(option.label),
                              selected: palette == option,
                              onSelected: (_) => onPaletteSelected(option),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '日文原文',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<double>(
                        key: const ValueKey('wenku-reader-japanese-opacity'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: .45, label: Text('弱')),
                          ButtonSegment(value: .68, label: Text('标准')),
                          ButtonSegment(value: .9, label: Text('清晰')),
                        ],
                        selected: {japaneseOpacity},
                        onSelectionChanged: (value) =>
                            onJapaneseOpacitySelected(value.single),
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                      Text('字号', style: Theme.of(context).textTheme.labelLarge),
                      for (final option in const <(double, String)>[
                        (15, '小字号'),
                        (18, '标准字号'),
                        (22, '大字号'),
                        (26, '特大字号'),
                      ])
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            currentFontSize == option.$1
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 20,
                          ),
                          title: Text(option.$2),
                          onTap: () => onFontSizeSelected(option.$1),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Color _colorFromHex(String value) =>
    Color(int.parse(value.substring(1), radix: 16) | 0xff000000);

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
