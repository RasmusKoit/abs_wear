import 'package:abs_wear/app/crown.dart';
import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MockStreamHandlerEventSink? crown;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          crownChannel,
          MockStreamHandler.inline(
            onListen: (_, sink) {
              crown = sink;
            },
          ),
        );
  });

  Widget list(ScrollController controller) => CrownScrollbar(
    controller: controller,
    child: ListView.builder(
      controller: controller,
      itemCount: 100,
      itemBuilder: (_, i) => SizedBox(height: 50, child: Text('$i')),
    ),
  );

  // Platform events arrive asynchronously; let them through, then animate.
  Future<void> turn(WidgetTester tester, {required bool clockwise}) async {
    await tester.runAsync(() async {
      crown!.success(clockwise);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('only the page on top scrolls with the crown', (tester) async {
    final below = ScrollController();
    final top = ScrollController();
    addTearDown(below.dispose);
    addTearDown(top.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: list(below)),
    );

    await turn(tester, clockwise: true);
    expect(below.offset, 50);

    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => list(top)),
    );
    await tester.pumpAndSettle();
    await turn(tester, clockwise: true);
    await turn(tester, clockwise: true);

    expect(top.offset, 100);
    expect(below.offset, 50); // Hidden page didn't move.

    await turn(tester, clockwise: false);
    expect(top.offset, 50);
  });
}
