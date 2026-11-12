import 'package:abs_wear/player/darts/audio_output.dart';
import 'package:abs_wear/player/view/headphone_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('audio_output');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;
  late bool headphones;

  setUp(() {
    calls = [];
    headphones = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'hasHeadphones' => headphones,
        'openBluetoothSettings' => true,
        _ => null,
      };
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  // Pumps a button that runs the check and records its answer.
  Future<List<bool>> pumpCheck(WidgetTester tester) async {
    final answers = <bool>[];
    await tester.pumpApp(
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => answers.add(await confirmAudioOutput(context)),
          child: const Text('Play'),
        ),
      ),
    );
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    return answers;
  }

  test('without the platform side, headphones count as connected', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await AudioOutput.hasHeadphones(), isTrue);
    expect(await AudioOutput.openBluetoothSettings(), isFalse);
  });

  testWidgets('plays without asking when headphones are connected', (
    tester,
  ) async {
    headphones = true;
    final answers = await pumpCheck(tester);
    expect(answers, [true]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('speaker choice plays', (tester) async {
    final answers = await pumpCheck(tester);
    expect(find.text('No headphones connected.'), findsOneWidget);
    expect(calls, contains('watch'));
    await tester.tap(find.byTooltip('Play on the watch speaker'));
    await tester.pumpAndSettle();
    expect(answers, [true]);
    expect(calls.last, 'unwatch');
  });

  testWidgets('connect opens Bluetooth settings and keeps the prompt', (
    tester,
  ) async {
    final answers = await pumpCheck(tester);
    await tester.tap(find.byTooltip('Connect headphones'));
    await tester.pumpAndSettle();
    expect(calls, contains('openBluetoothSettings'));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(answers, isEmpty);
  });

  testWidgets('plays once headphones connect', (tester) async {
    final answers = await pumpCheck(tester);
    await simulatePlatformCall('audio_output', 'changed', false);
    await tester.pumpAndSettle();
    expect(answers, isEmpty);
    await simulatePlatformCall('audio_output', 'changed', true);
    await tester.pumpAndSettle();
    expect(answers, [true]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final speaker in [true, false]) {
    testWidgets('a late connect does not pop the page under the prompt '
        '(speaker: $speaker)', (tester) async {
      await tester.pumpApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => confirmAudioOutput(context),
                    child: const Text('Play'),
                  ),
                ),
              ),
            ),
            child: const Text('Open player'),
          ),
        ),
      );
      await tester.tap(find.text('Open player'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      if (speaker) {
        await tester.tap(find.byTooltip('Play on the watch speaker'));
      } else {
        await tester.tapAt(const Offset(1, 1));
      }
      await tester.pump();
      // Still closing: the dialog's state is mounted.
      await simulatePlatformCall('audio_output', 'changed', true);
      await tester.pumpAndSettle();
      expect(find.text('Play'), findsOneWidget);
    });
  }

  testWidgets('dismissing does not play', (tester) async {
    final answers = await pumpCheck(tester);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });
}
