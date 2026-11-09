import 'dart:async';

import 'package:abs_wear/app/crown.dart';
import 'package:abs_wear/app/view/round_scrollbar.dart';
import 'package:flutter/material.dart';

/// Crown (rotary) scrolling plus a round scrollbar, active only while its
/// page is on top.
///
/// Crown turns arrive on one app-wide stream and pages under the current
/// one stay mounted, so each listener checks that its page is on top;
/// otherwise a hidden list would scroll along with the visible one.
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

  StreamSubscription<bool>? _subscription;

  /// Where consecutive detents are heading, so fast turns add up instead
  /// of restarting from the current (animating) offset.
  double? _target;
  int _detent = 0;

  @override
  void initState() {
    super.initState();
    _subscription = crownTurns.listen(_onCrown);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _onCrown(bool clockwise) {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final controller = widget.controller;
    if (!controller.hasClients) return;
    final forward = clockwise;

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
    return RoundScrollbar(controller: widget.controller, child: widget.child);
  }
}
