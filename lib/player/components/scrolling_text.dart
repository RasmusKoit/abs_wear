import 'dart:async';

import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:flutter/material.dart';

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

  @override
  void didUpdateWidget(ScrollingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _stop();
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

  /// Scrolls the text once after a short delay.
  void _scheduleScroll({Duration delay = _delay}) {
    _start?.cancel();
    _start = Timer(delay, () {
      if (!mounted || !_overflows) return;
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
        final direction = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        TextPainter measure(String text) => TextPainter(
          text: TextSpan(text: text, style: widget.style),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final textPainter = measure(widget.text);
        _overflows = textPainter.width > constraints.maxWidth;
        textPainter.dispose();
        if (!_overflows) return staticText;
        if (ScrollingText._scrolled.add(widget.text)) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scheduleScroll(),
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
            child: SizedBox(
              width: constraints.maxWidth,
              child: OverflowBox(
                alignment: AlignmentDirectional.centerStart,
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
                    maxLines: 1,
                    softWrap: false,
                    style: widget.style,
                  ),
                ),
              ),
            ),
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: scrolling ? null : () => _scheduleScroll(delay: Duration.zero),
          child: RepaintBoundary(child: line),
        );
      },
    );
  }
}
