import 'dart:async';
import 'dart:math' as math;

import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/volume.dart';
import 'package:flutter/material.dart';
import 'package:volume_controller/volume_controller.dart';

/// Crown detents step the volume and briefly show it; swipes still page.
class CrownVolume extends StatefulWidget {
  const CrownVolume({required this.controller, required this.child, super.key});

  /// Volume change per crown detent.
  static const double step = 0.05;

  /// How long the level stays on screen after the last detent.
  static const shownFor = Duration(milliseconds: 1500);

  /// Shown in the round scrollbar; the crown does not move it.
  final ScrollController controller;
  final Widget child;

  @override
  State<CrownVolume> createState() => _CrownVolumeState();
}

class _CrownVolumeState extends State<CrownVolume> {
  final _level = ValueNotifier<double>(0);
  final _visible = ValueNotifier<bool>(false);
  Future<void> _pending = Future.value();
  Timer? _hide;

  /// Target of the current detent run, so steps add up past system rounding.
  double? _target;

  /// System level right after the crown's last change, to spot other changes.
  double? _settled;

  @override
  void dispose() {
    _hide?.cancel();
    _level.dispose();
    _visible.dispose();
    super.dispose();
  }

  void _onTurn(bool clockwise) {
    // One at a time, so fast turns don't read the same starting level.
    _pending = _pending.then((_) => _step(clockwise));
  }

  Future<void> _step(bool clockwise) async {
    if (!_onTop) return;
    final volume = VolumeController.instance;
    final double level;
    try {
      final current = await volume.getVolume();
      // Another control (buttons, hardware keys) moved it: start from there.
      final from = current == _settled ? _target : current;
      if (!_onTop) return;
      level = await changeVolume(
        clockwise ? CrownVolume.step : -CrownVolume.step,
        from: from,
      );
      _settled = await volume.getVolume();
    } on Exception {
      return;
    }
    if (!mounted) return;
    _target = level;
    _level.value = level;
    _visible.value = true;
    _hide?.cancel();
    _hide = Timer(CrownVolume.shownFor, () {
      _target = null;
      _settled = null;
      if (mounted) _visible.value = false;
    });
  }

  bool get _onTop => mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  Widget build(BuildContext context) {
    return CrownScrollbar(
      controller: widget.controller,
      onTurn: _onTurn,
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: ListenableBuilder(
                listenable: Listenable.merge([_level, _visible]),
                builder: (context, _) => AnimatedOpacity(
                  opacity: _visible.value ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: VolumeIndicator(level: _level.value),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Volume [level] as a left-edge arc on the round screen plus a percentage.
class VolumeIndicator extends StatelessWidget {
  const VolumeIndicator({required this.level, super.key});

  final double level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (level * 100).round();
    return CustomPaint(
      painter: _VolumeArcPainter(
        level: level,
        track: theme.highlightColor,
        fill: theme.colorScheme.primary,
      ),
      child: Align(
        alignment: const Alignment(0, -0.7),
        child: Semantics(
          liveRegion: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(volumeIcon(level), size: 16),
                  const SizedBox(width: 4),
                  Text(
                    '$percent%',
                    style: theme.textTheme.labelSmall,
                    semanticsLabel: context.l10n.volumeLevel(percent),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VolumeArcPainter extends CustomPainter {
  _VolumeArcPainter({
    required this.level,
    required this.track,
    required this.fill,
  });

  // 7 o'clock, sweeping up to 11 o'clock.
  static const double _start = math.pi * 2 / 3;
  static const double _sweep = math.pi * 2 / 3;
  static const double _width = 4;
  static const double _padding = 1;

  final double level;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width - _padding * 2 - _width,
      height: size.height - _padding * 2 - _width,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _width
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _start, _sweep, false, paint..color = track);
    if (level > 0) {
      canvas.drawArc(rect, _start, _sweep * level, false, paint..color = fill);
    }
  }

  @override
  bool shouldRepaint(_VolumeArcPainter old) =>
      old.level != level || old.track != track || old.fill != fill;
}
