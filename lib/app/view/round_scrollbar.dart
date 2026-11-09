import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A thin scrollbar along the right edge of a round screen, from the
/// 2 o'clock to the 4 o'clock position. Shown while [controller]'s content
/// is larger than its viewport; it repaints on scroll without rebuilding.
class RoundScrollbar extends StatefulWidget {
  const RoundScrollbar({
    required this.controller,
    required this.child,
    this.width = 2,
    this.padding = 1,
    super.key,
  });

  final ScrollController controller;
  final Widget child;

  /// Stroke width of the arc.
  final double width;

  /// Gap between the arc and the edge of this widget.
  final double padding;

  @override
  State<RoundScrollbar> createState() => _RoundScrollbarState();
}

class _RoundScrollbarState extends State<RoundScrollbar> {
  /// Bumped when the content or viewport size changes without a scroll.
  final _metrics = ValueNotifier<int>(0);

  @override
  void dispose() {
    _metrics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).highlightColor;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _metrics.value++;
        return false;
      },
      child: CustomPaint(
        foregroundPainter: _ArcPainter(
          controller: widget.controller,
          repaint: Listenable.merge([widget.controller, _metrics]),
          track: highlight,
          thumb: highlight.withAlpha(255),
          width: widget.width,
          padding: widget.padding,
        ),
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({
    required this.controller,
    required Listenable repaint,
    required this.track,
    required this.thumb,
    required this.width,
    required this.padding,
  }) : super(repaint: repaint);

  // 2 o'clock, sweeping a third of a half turn to 4 o'clock.
  static const double _start = -math.pi / 6;
  static const double _sweep = math.pi / 3;

  final ScrollController controller;
  final Color track;
  final Color thumb;
  final double width;
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.hasClients || controller.positions.length != 1) return;
    final position = controller.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final total = position.maxScrollExtent - position.minScrollExtent;
    if (total <= 0) return;
    final viewport = position.viewportDimension;
    final thumbSweep = _sweep * viewport / (total + viewport);
    final progress = ((position.pixels - position.minScrollExtent) / total)
        .clamp(0.0, 1.0);
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width - padding * 2 - width,
      height: size.height - padding * 2 - width,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawArc(rect, _start, _sweep, false, paint..color = track)
      ..drawArc(
        rect,
        _start + (_sweep - thumbSweep) * progress,
        thumbSweep,
        false,
        paint..color = thumb,
      );
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.controller != controller ||
      old.track != track ||
      old.thumb != thumb ||
      old.width != width ||
      old.padding != padding;
}
