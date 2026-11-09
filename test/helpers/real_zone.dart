import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pump_app.dart';

/// For pages whose loading does real async work (file IO, isolates) or
/// touches the player's static futures (AudioPlayerController's push
/// queue): a future left in a test's fake-async zone never completes once
/// that test ended, and a static one would hang whichever test chains on
/// it next. Started in the real zone, they run on the real event loop, so
/// test order can't matter.
///
/// Frames are pumped in the real zone too, so work started from a build or
/// a post-frame callback (a list loading its next page) runs there.
extension RealZone on WidgetTester {
  /// Pumps [widget] in the real zone, so its initState work runs there.
  Future<void> pumpAppInRealZone(Widget widget) =>
      runAsync(() => pumpApp(widget));

  /// Taps [finder] in the real zone, so the work it starts runs there.
  Future<void> tapInRealZone(Finder finder) => runAsync(() async {
    await tap(finder);
    await pump();
  });

  /// Drags [finder] by [offset] in the real zone and builds what scrolled
  /// into view.
  Future<void> dragInRealZone(Finder finder, Offset offset) =>
      runAsync(() async {
        await drag(finder, offset);
        await pump();
      });

  /// Lets real async work run and rebuilds, until [done] holds (or about
  /// three seconds passed), then a little longer for follow-up work such
  /// as cache writes.
  Future<void> settleRealZone({bool Function()? done}) async {
    for (var i = 0; done != null && i < 100 && !done(); i++) {
      await _turn();
    }
    for (var i = 0; i < 5; i++) {
      await _turn();
    }
  }

  Future<void> _turn() => runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await pump();
  });
}
