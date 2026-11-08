import 'package:flutter/widgets.dart';

/// Turns a pull past the top of a scrollable page into a swipe back to the
/// previous page of [controller].
///
/// A page that scrolls keeps every vertical drag for itself, so without this
/// the outer [PageView] can never be swiped back from it (only the crown
/// would page back).
class OverscrollToPreviousPage extends StatefulWidget {
  const OverscrollToPreviousPage({
    required this.controller,
    required this.child,
    super.key,
  });

  final PageController controller;
  final Widget child;

  @override
  State<OverscrollToPreviousPage> createState() =>
      _OverscrollToPreviousPageState();
}

class _OverscrollToPreviousPageState extends State<OverscrollToPreviousPage> {
  /// How far a drag must pull past the top before the page goes back, so
  /// a twitch at the top doesn't leave the page.
  static const double _threshold = 24;

  /// Only a drag that starts with the page at its top goes back; one that
  /// scrolls the page up to its top stops there.
  bool _armed = false;
  double _pulled = 0;

  bool _onNotification(ScrollNotification notification) {
    // Only the page's own scrollable, not lists nested deeper inside it.
    if (notification.depth != 0) return false;
    switch (notification) {
      case ScrollStartNotification(:final metrics):
        _armed = metrics.pixels <= metrics.minScrollExtent;
        _pulled = 0;
      case OverscrollNotification(:final overscroll, :final dragDetails)
          // Pulled down at the top by a finger; a fling that runs into the
          // top on its own stays on this page.
          when overscroll < 0 && dragDetails != null && _armed:
        _pulled -= overscroll;
        if (_pulled < _threshold) break;
        _armed = false;
        if (widget.controller.hasClients) {
          widget.controller.previousPage(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      default:
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onNotification,
        child: widget.child,
      );
}
