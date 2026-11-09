import 'package:abs_wear/app/toast.dart';
import 'package:abs_wear/app/view/round_scrollbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const toast = MethodChannel('toast');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(toast, null));

  test('showToast sends the message and length', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(toast, (call) async {
      calls.add(call);
      return null;
    });
    await showToast('Hi', long: true);
    await showToast('Bye');
    expect(calls.map((c) => c.method), ['show', 'show']);
    expect(calls[0].arguments, {'message': 'Hi', 'long': true});
    expect(calls[1].arguments, {'message': 'Bye', 'long': false});
  });

  test('showToast never throws', () async {
    // No handler: MissingPluginException.
    await showToast('Nobody listens');
    messenger.setMockMethodCallHandler(
      toast,
      (_) async => throw PlatformException(code: 'boom'),
    );
    await showToast('Fails');
  });

  Widget scrollable(ScrollController controller, int items) => MaterialApp(
    home: RoundScrollbar(
      controller: controller,
      child: ListView.builder(
        controller: controller,
        itemCount: items,
        itemBuilder: (_, i) => SizedBox(height: 50, child: Text('$i')),
      ),
    ),
  );

  testWidgets('round scrollbar paints for long and short lists', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(scrollable(controller, 100));
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    controller.jumpTo(0);
    await tester.pump();
    // Content now fits: nothing to draw, no errors.
    await tester.pumpWidget(scrollable(controller, 1));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(RoundScrollbar), findsOneWidget);
  });
}
