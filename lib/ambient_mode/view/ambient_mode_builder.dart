import 'package:audiobookshelfwear/ambient_mode/ambient_mode.dart';
import 'package:flutter/widgets.dart';

class AmbientModeBuilder extends StatelessWidget {
  AmbientModeBuilder({
    required this.builder,
    super.key,
    this.child,
    @visibleForTesting AmbientModeListener? listener,
  }) : _listener = listener ?? AmbientModeListener.instance;

  final AmbientModeListener _listener;

  final ValueWidgetBuilder<bool> builder;

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: _listener,
      builder: builder,
      child: child,
    );
  }
}
