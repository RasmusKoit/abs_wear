import 'package:flutter/widgets.dart';

/// Whether the app is on screen (resumed, or inactive under a system
/// overlay). Dart timers keep running while the app is hidden or cached, so
/// periodic UI work checks this and stops.
class AppVisibility extends ValueNotifier<bool> with WidgetsBindingObserver {
  AppVisibility._() : super(true);

  static final AppVisibility instance = AppVisibility._();

  bool _observing = false;

  /// Starts following the app lifecycle (once).
  void ensureInitialized() {
    if (_observing) return;
    _observing = true;
    final binding = WidgetsBinding.instance..addObserver(this);
    _update(binding.lifecycleState);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _update(state);

  void _update(AppLifecycleState? state) {
    value =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }
}
