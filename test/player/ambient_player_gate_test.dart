import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:abs_wear/player/view/player_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  tearDown(() => AmbientModeListener.instance.value = false);

  AudioPlayerController loaded() => AudioPlayerController()
    ..isLoaded = true
    ..bookTitle = 'The Book'
    ..duration = 600
    ..chapters = const [BookChapter(start: 0, end: 600, title: 'One')];

  testWidgets('any player page shows the always-on layout while ambient', (
    tester,
  ) async {
    var builds = 0;
    await tester.pumpApp(
      Scaffold(
        body: AmbientPlayerGate(
          playerController: loaded(),
          child: Builder(
            builder: (context) {
              builds++;
              return const Text('controls');
            },
          ),
        ),
      ),
    );
    expect(find.text('controls'), findsOneWidget);

    AmbientModeListener.instance.value = true;
    await tester.pump();
    expect(find.text('controls'), findsNothing);
    expect(find.text('The Book'), findsOneWidget);
    expect(find.text('00:10'), findsOneWidget);

    AmbientModeListener.instance.value = false;
    await tester.pump();
    expect(find.text('controls'), findsOneWidget);
    expect(builds, 2);
  });
}
