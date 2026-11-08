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
  /// Pages back once per drag, not on every overscroll event of it.
  bool _handled = false;

  bool _onNotification(ScrollNotification notification) {
    // Only the page's own scrollable, not lists nested deeper inside it.
    if (notification.depth != 0) return false;
    switch (notification) {
      case ScrollStartNotification():
        _handled = false;
      case OverscrollNotification(:final overscroll, :final dragDetails)
          // Pulled down at the top by a finger; a fling that runs into the
          // top on its own stays on this page.
          when overscroll < 0 && dragDetails != null && !_handled:
        _handled = true;
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
