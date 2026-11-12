import 'package:abs_wear/app/crown.dart';
import 'package:abs_wear/player/view/crown_volume.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/helpers.dart';

void main() {
  const volumeChannel = MethodChannel(
    'com.kurenai7968.volume_controller.method',
  );
  MockStreamHandlerEventSink? crown;
  late double systemVolume;
  late List<double> setVolumes;
  late List<bool> showSystemUi;

  setUp(() {
    systemVolume = 0.5;
    setVolumes = [];
    showSystemUi = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockStreamHandler(
        crownChannel,
        MockStreamHandler.inline(
          onListen: (_, sink) {
            crown = sink;
          },
        ),
      )
      ..setMockMethodCallHandler(volumeChannel, (call) async {
        if (call.method == 'getVolume') return systemVolume;
        if (call.method == 'setVolume') {
          final args = call.arguments as Map<Object?, Object?>;
          // Like a 15-step media stream: the system rounds each request.
          final asked = args['volume']! as double;
          systemVolume = (asked * 15).round() / 15;
          setVolumes.add(asked);
          showSystemUi.add(args['showSystemUI']! as bool);
        }
        return null;
      });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockStreamHandler(crownChannel, null)
      ..setMockMethodCallHandler(volumeChannel, null);
  });

  Future<PageController> pumpPlayer(WidgetTester tester) async {
    final pages = PageController();
    addTearDown(pages.dispose);
    await tester.pumpApp(
      CrownVolume(
        controller: pages,
        child: PageView(
          scrollDirection: Axis.vertical,
          controller: pages,
          children: const [Text('player'), Text('controls')],
        ),
      ),
    );
    return pages;
  }

  // Platform events and calls are async; let them through, then build.
  Future<void> turn(WidgetTester tester, {required bool clockwise}) async {
    await tester.runAsync(() async {
      crown!.success(clockwise);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    // One pump runs the volume call's continuation, the next shows it.
    await tester.pump();
    await tester.pump();
  }

  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byType(VolumeIndicator),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('crown steps the volume instead of the page', (tester) async {
    final pages = await pumpPlayer(tester);
    expect(opacity(tester), 0);

    await turn(tester, clockwise: true);

    expect(setVolumes, [closeTo(0.55, 1e-9)]);
    expect(showSystemUi, [false]);
    expect(pages.page, 0);
    expect(opacity(tester), 1);
    expect(find.text('55%'), findsOneWidget);

    await turn(tester, clockwise: false);
    await turn(tester, clockwise: false);
    expect(setVolumes.last, closeTo(0.45, 1e-9));
    expect(find.text('45%'), findsOneWidget);
    expect(pages.page, 0);
  });

  testWidgets('small steps add up past the system rounding', (tester) async {
    await pumpPlayer(tester);

    await turn(tester, clockwise: true);
    await turn(tester, clockwise: true);
    await turn(tester, clockwise: true);

    // Not stuck re-reading the rounded level: 0.5 + 3 x 0.05.
    expect(setVolumes.last, closeTo(0.65, 1e-9));
  });

  testWidgets('volume stops at 0 and 1', (tester) async {
    systemVolume = 0.98;
    await pumpPlayer(tester);

    await turn(tester, clockwise: true);
    expect(setVolumes.last, 1);
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('the level hides a moment after the last detent', (tester) async {
    await pumpPlayer(tester);
    await turn(tester, clockwise: true);

    await tester.pump(CrownVolume.shownFor);
    await tester.pumpAndSettle();
    expect(opacity(tester), 0);

    // A new run starts from the system's (rounded) level again.
    final rounded = systemVolume;
    await turn(tester, clockwise: true);
    expect(setVolumes.last, closeTo(rounded + 0.05, 1e-9));
    expect(opacity(tester), 1);
  });

  testWidgets('swiping still reaches the next page', (tester) async {
    final pages = await pumpPlayer(tester);

    await tester.fling(find.text('player'), const Offset(0, -300), 1000);
    await tester.pumpAndSettle();

    expect(pages.page, 1);
    expect(setVolumes, isEmpty);
  });
}
