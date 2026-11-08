import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rotary_scrollbar/rotary_scrollbar.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

/// Crown (rotary) scrolling plus a round scrollbar, active only while its
/// page is on top.
///
/// The package's RotaryScrollbar listens to the global rotary stream for
/// as long as it is mounted, and pages under the current one stay mounted,
/// so a hidden list would scroll along with the visible one.
class CrownScrollbar extends StatefulWidget {
  const CrownScrollbar({
    required this.controller,
    required this.child,
    super.key,
  });

  /// A [PageController] moves a page per detent; any other controller
  /// scrolls 50 px per detent.
  final ScrollController controller;
  final Widget child;

  @override
  State<CrownScrollbar> createState() => _CrownScrollbarState();
}

class _CrownScrollbarState extends State<CrownScrollbar> {
  static const double _step = 50;
  static const _duration = Duration(milliseconds: 150);

  StreamSubscription<RotaryEvent>? _subscription;

  /// Where consecutive detents are heading, so fast turns add up instead
  /// of restarting from the current (animating) offset.
  double? _target;
  int _detent = 0;

  @override
  void initState() {
    super.initState();
    _subscription = rotaryEvents.listen(_onRotary);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _onRotary(RotaryEvent event) {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final controller = widget.controller;
    if (!controller.hasClients) return;
    final forward = event.direction == RotaryDirection.clockwise;

    if (controller is PageController) {
      unawaited(
        forward
            ? controller.nextPage(duration: _duration, curve: Curves.easeOut)
            : controller.previousPage(
                duration: _duration,
                curve: Curves.easeOut,
              ),
      );
      return;
    }
    final position = controller.position;
    final from = _target ?? position.pixels;
    final to = (from + (forward ? _step : -_step)).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _target = to;
    final detent = ++_detent;
    unawaited(
      controller
          .animateTo(to, duration: _duration, curve: Curves.easeOut)
          .whenComplete(() {
            // Only the latest detent's animation ends the run.
            if (detent == _detent) _target = null;
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RoundScrollbar(
      controller: widget.controller,
      width: 2,
      padding: 1,
      autoHide: false,
      child: widget.child,
    );
  }
}
