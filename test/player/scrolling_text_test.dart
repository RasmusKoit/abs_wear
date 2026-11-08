import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:abs_wear/player/components/scrolling_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:text_scroll/text_scroll.dart';

void main() {
  Widget app() => const MaterialApp(
    home: Scaffold(
      body: ScrollingText(text: 'A long book title', style: TextStyle()),
    ),
  );

  tearDown(() => AmbientModeListener.instance.value = false);

  testWidgets('scrolls the text normally', (tester) async {
    AmbientModeListener.instance.value = false;
    await tester.pumpWidget(app());
    expect(find.byType(TextScroll), findsOneWidget);
  });

  testWidgets('shows static text in ambient mode', (tester) async {
    AmbientModeListener.instance.value = true;
    await tester.pumpWidget(app());
    expect(find.byType(TextScroll), findsNothing);
    expect(find.text('A long book title'), findsOneWidget);
  });
}
