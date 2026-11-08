import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:abs_wear/player/components/scrolling_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const long = 'A very long book title that never fits on a watch';

  // Like the player: a line in a Column, so its height is unbounded.
  Widget app(String text, {TextDirection ui = TextDirection.ltr}) =>
      MaterialApp(
        builder: (context, child) =>
            Directionality(textDirection: ui, child: child!),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScrollingText(text: text, style: const TextStyle()),
                  const Text('below'),
                ],
              ),
            ),
          ),
        ),
      );

  setUp(ScrollingText.resetScrolled);
  tearDown(() => AmbientModeListener.instance.value = false);

  Finder doubled(String text) => find.textContaining('$text\u00A0');

  testWidgets('short text stays static and schedules nothing', (tester) async {
    await tester.pumpWidget(app('Short'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Short'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('long text scrolls once, then stops drawing frames', (
    tester,
  ) async {
    await tester.pumpWidget(app(long));
    await tester.pump();
    expect(find.text(long), findsOneWidget);
    final height = tester.getSize(find.byType(ScrollingText)).height;
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(doubled(long), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(ScrollingText)).height, height);
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(doubled(long), findsNothing);
    expect(find.text(long), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  /// Shows [long] and lets its first scroll run to the end.
  Future<void> scrollOnce(WidgetTester tester) async {
    await tester.pumpWidget(app(long));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(doubled(long), findsNothing);
  }

  testWidgets('the same text does not scroll by itself again', (tester) async {
    await scrollOnce(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(long));
    await tester.pump(const Duration(seconds: 3));
    expect(doubled(long), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a line closed before its scroll started still scrolls later', (
    tester,
  ) async {
    await tester.pumpWidget(app(long));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(long));
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(doubled(long), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a long text shown again after a short one still scrolls', (
    tester,
  ) async {
    await tester.pumpWidget(app(long));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(app('Short'));
    await tester.pump();
    await tester.pumpWidget(app(long));
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(doubled(long), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a left-to-right title in a right-to-left UI starts at its '
      'start', (tester) async {
    await tester.pumpWidget(app(long, ui: TextDirection.rtl));
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump();
    final line = tester.getRect(find.byType(ScrollingText));
    final text = tester.getRect(doubled(long));
    expect(text.left, moreOrLessEquals(line.left, epsilon: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('a tap scrolls it again', (tester) async {
    await scrollOnce(tester);
    await tester.tap(find.text(long));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(doubled(long), findsOneWidget);
    await tester.pumpAndSettle();
    expect(doubled(long), findsNothing);
  });

  testWidgets('shows static text in ambient mode', (tester) async {
    AmbientModeListener.instance.value = true;
    await tester.pumpWidget(app(long));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(long), findsOneWidget);
    expect(doubled(long), findsNothing);
  });
}
