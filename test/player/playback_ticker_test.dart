import 'dart:async';

import 'package:abs_wear/app/app_visibility.dart';
import 'package:abs_wear/player/view/player_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<bool> playing;
  late StreamController<Object?> changes;
  late int builds;

  setUp(() {
    playing = StreamController<bool>.broadcast();
    changes = StreamController<Object?>.broadcast();
    builds = 0;
  });

  tearDown(() async {
    AppVisibility.instance.value = true;
    await playing.close();
    await changes.close();
  });

  Widget ticker() => PlaybackTicker(
    playing: playing.stream,
    changes: changes.stream,
    builder: (context) {
      builds++;
      return const SizedBox();
    },
  );

  testWidgets('ticks once a second only while playing', (tester) async {
    await tester.pumpWidget(ticker());
    await tester.pump();
    builds = 0;
    await tester.pump(const Duration(seconds: 5));
    expect(builds, 0, reason: 'paused: no rebuilds');

    playing.add(true);
    await tester.pump();
    await tester.pump();
    builds = 0;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(builds, 3);

    playing.add(false);
    await tester.pump();
    await tester.pump();
    builds = 0;
    await tester.pump(const Duration(seconds: 5));
    expect(builds, 0);
  });

  testWidgets('rebuilds on player events while paused (seeks)', (tester) async {
    await tester.pumpWidget(ticker());
    await tester.pump();
    builds = 0;
    changes.add(null);
    await tester.pump();
    await tester.pump();
    expect(builds, 1);
  });

  testWidgets('stops ticking while the app is hidden', (tester) async {
    await tester.pumpWidget(ticker());
    playing.add(true);
    await tester.pump();
    await tester.pump();

    AppVisibility.instance.value = false;
    await tester.pump();
    builds = 0;
    await tester.pump(const Duration(seconds: 5));
    expect(builds, 0);

    AppVisibility.instance.value = true;
    await tester.pump();
    builds = 0;
    await tester.pump(const Duration(seconds: 1));
    expect(builds, 1);
  });

  testWidgets('cancels its timer when disposed', (tester) async {
    await tester.pumpWidget(ticker());
    playing.add(true);
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    // A live periodic timer would fail the test at teardown.
  });
}
