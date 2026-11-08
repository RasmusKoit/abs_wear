import 'package:abs_wear/app/view/overscroll_to_previous_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late PageController pages;
  late ScrollController list;

  setUp(() {
    pages = PageController();
    list = ScrollController();
  });

  tearDown(() {
    pages.dispose();
    list.dispose();
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: PageView(
        scrollDirection: Axis.vertical,
        controller: pages,
        children: [
          const Center(child: Text('player')),
          OverscrollToPreviousPage(
            controller: pages,
            child: SingleChildScrollView(
              controller: list,
              child: Column(
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 50, child: Text('row $i')),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> toSecondPage(WidgetTester tester) async {
    pages.jumpToPage(1);
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsOneWidget);
  }

  testWidgets('pulling down at the top goes back a page', (tester) async {
    await pump(tester);
    await toSecondPage(tester);

    await tester.drag(find.text('row 2'), const Offset(0, 200));
    await tester.pumpAndSettle();

    expect(pages.page, 0);
    expect(find.text('player'), findsOneWidget);
  });

  testWidgets('scrolls the list until it reaches the top', (tester) async {
    await pump(tester);
    await toSecondPage(tester);
    list.jumpTo(500);
    await tester.pump();

    // Moves the list back up without running past its top.
    await tester.drag(find.text('row 12'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    // 200 px less the drag's touch slop.
    final afterUp = list.offset;
    expect(afterUp, inExclusiveRange(250, 350));

    // Scrolling down the list stays on the page too.
    await tester.drag(find.text('row 8'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    expect(list.offset, greaterThan(afterUp + 150));
  });

  testWidgets('a drag that scrolls up to the top stops there', (tester) async {
    await pump(tester);
    await toSecondPage(tester);
    list.jumpTo(100);
    await tester.pump();

    // Scrolls 100 px to the top, then keeps pulling in the same drag.
    await tester.drag(find.text('row 5'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(list.offset, 0);
    expect(pages.page, 1);

    // A new pull from the top goes back.
    await tester.drag(find.text('row 2'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(pages.page, 0);
  });

  testWidgets('a short twitch at the top stays on the page', (tester) async {
    await pump(tester);
    await toSecondPage(tester);

    // Past the touch slop, but less than the threshold.
    await tester.drag(find.text('row 2'), const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
  });

  testWidgets('a fling into the top stays on the page', (tester) async {
    await pump(tester);
    await toSecondPage(tester);
    list.jumpTo(150);
    await tester.pump();

    // Starts scrolling 150 px from the top and coasts into it.
    await tester.fling(find.text('row 5'), const Offset(0, 100), 3000);
    await tester.pumpAndSettle();

    expect(list.offset, 0);
    expect(pages.page, 1);
  });
}
