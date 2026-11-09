import 'dart:async';

import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show Bidi;

/// One line of text. Text that doesn't fit scrolls past once, the first
/// time it is shown, then stays ellipsized; a tap scrolls it again.
///
/// An endless marquee redrew the screen at the display's frame rate for as
/// long as the player was open, the app's biggest battery drain.
class ScrollingText extends StatefulWidget {
  const ScrollingText({required this.text, required this.style, super.key});
  final String text;
  final TextStyle style;

  /// Texts that already scrolled by themselves in this run of the app, so
  /// waking the screen doesn't scroll the same title again.
  static final Set<String> _scrolled = {};

  @visibleForTesting
  static void resetScrolled() => _scrolled.clear();

  @override
  State<ScrollingText> createState() => _ScrollingTextState();
}

class _ScrollingTextState extends State<ScrollingText>
    with SingleTickerProviderStateMixin {
  static const _gap = '\u00A0\u00A0\u00A0\u00A0\u00A0\u00A0';
  static const _speed = 25.0; // Logical pixels per second.
  static const _delay = Duration(milliseconds: 1500);

  late final AnimationController _scroll = AnimationController(vsync: this)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _scroll.value = 0);
      }
    });
  Timer? _start;

  /// Whether the text overflowed at the last layout.
  bool _overflows = false;

  /// The text this state already scheduled its automatic scroll for.
  String? _autoScheduled;

  @override
  void didUpdateWidget(ScrollingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _stop();
      _autoScheduled = null;
    }
  }

  @override
  void dispose() {
    _start?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _stop() {
    _start?.cancel();
    _start = null;
    _scroll
      ..stop()
      ..value = 0;
  }

  /// Scrolls the text once after a short delay. An automatic scroll runs
  /// only for text that hasn't scrolled by itself yet; it is marked when it
  /// starts, so a line that goes away before then still scrolls next time.
  void _scheduleScroll({Duration delay = _delay, bool auto = false}) {
    _start?.cancel();
    _start = Timer(delay, () {
      _start = null;
      if (!mounted || !_overflows) return;
      if (auto && !ScrollingText._scrolled.add(widget.text)) return;
      _scroll.forward(from: 0);
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final ambient = AmbientModeListener.instance.isAmbientModeActive;
    final staticText = Text(
      widget.text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: widget.style,
    );
    // Ambient mode mutes tickers, so a running scroll just waits.
    if (ambient) return staticText;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The text's own direction (a Latin title in an Arabic UI still
        // reads left to right), so it scrolls from its start.
        final direction = Bidi.detectRtlDirectionality(widget.text)
            ? TextDirection.rtl
            : TextDirection.ltr;
        final scaler = MediaQuery.textScalerOf(context);
        // Measure with the style the Text widgets will use.
        final inherited = DefaultTextStyle.of(context);
        var style = inherited.style.merge(widget.style);
        if (MediaQuery.boldTextOf(context)) {
          style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
        }
        TextPainter measure(String text) => TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: direction,
          textScaler: scaler,
          textHeightBehavior: inherited.textHeightBehavior,
          maxLines: 1,
        )..layout();
        final textPainter = measure(widget.text);
        _overflows = textPainter.width > constraints.maxWidth;
        final height = textPainter.height;
        textPainter.dispose();
        if (!_overflows) return staticText;
        if (_autoScheduled != widget.text &&
            !ScrollingText._scrolled.contains(widget.text)) {
          _autoScheduled = widget.text;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scheduleScroll(auto: true),
          );
        }
        // One round: the text and the gap, after which the second copy sits
        // where the first one started.
        final roundPainter = measure('${widget.text}$_gap');
        final round = roundPainter.width;
        roundPainter.dispose();
        _scroll.duration = Duration(
          milliseconds: (round * 1000 / _speed).round(),
        );
        final scrolling = _scroll.isAnimating;
        final Widget line;
        if (!scrolling) {
          line = staticText;
        } else {
          final sign = direction == TextDirection.rtl ? 1.0 : -1.0;
          line = ClipRect(
            // A fixed size: in a Column the height is unbounded.
            child: SizedBox(
              width: constraints.maxWidth,
              height: height,
              child: OverflowBox(
                alignment: direction == TextDirection.rtl
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                child: AnimatedBuilder(
                  animation: _scroll,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(sign * _scroll.value * round, 0),
                    child: child,
                  ),
                  child: Text(
                    '${widget.text}$_gap${widget.text}',
                    textDirection: direction,
                    maxLines: 1,
                    softWrap: false,
                    style: widget.style,
                  ),
                ),
              ),
            ),
          );
        }
        // The tap only replays the scroll, which a screen reader doesn't
        // need (it reads the whole text): no semantic tap action, which
        // would also be a 16 dp high tap target. While scrolling, the
        // doubled text is read once.
        return Semantics(
          label: scrolling ? widget.text : null,
          textDirection: scrolling ? direction : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: scrolling
                ? null
                : () => _scheduleScroll(delay: Duration.zero),
            child: RepaintBoundary(
              child: scrolling ? ExcludeSemantics(child: line) : line,
            ),
          ),
        );
      },
    );
  }
}
