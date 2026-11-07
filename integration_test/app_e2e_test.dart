// End-to-end tests against a real Audiobookshelf server.
//
// Run with tool/e2e.sh (it passes the server URL and credentials as
// --dart-define values read from tool/abs_test_server/.env).
import 'dart:async';

import 'package:abs_wear/app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

const absUrl = String.fromEnvironment('ABS_URL');
const absUser = String.fromEnvironment('ABS_TEST_USER');
const absPassword = String.fromEnvironment('ABS_TEST_PASSWORD');

/// Pumps frames until [finder] matches or [timeout] passes. Avoids
/// pumpAndSettle, which never settles while scrolling text or spinners
/// animate.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TimeoutException('Timed out waiting for $finder', timeout);
}

/// Scrolls [finder] into view (watch screens are tiny) and taps it.
Future<void> scrollAndTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);
}

Future<void> logInAndOpenLibrary(WidgetTester tester) async {
  await tester.pumpWidget(const App());
  await pumpUntil(tester, find.text('Login'));

  await tester.enterText(
    find.widgetWithText(TextFormField, 'Server URL'),
    absUrl,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Username'),
    absUser,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Password'),
    absPassword,
  );
  await scrollAndTap(tester, find.text('Login'));
  await pumpUntil(tester, find.text('Hello $absUser'));

  await scrollAndTap(tester, find.widgetWithText(ElevatedButton, 'Library'));
  await pumpUntil(tester, find.text('Single File Book'));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    assert(absUrl.isNotEmpty, 'Pass ABS_URL via --dart-define');
    await JustAudioBackground.init(
      androidNotificationChannelId: 'dev.koit.abs_wear.channel.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationOngoing: true,
    );
  });

  setUp(() async {
    // Start every test logged out.
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  testWidgets('logs in and lists Continue Listening', (tester) async {
    await logInAndOpenLibrary(tester);

    expect(find.text('Single File Book'), findsOneWidget);
    expect(find.text('Multi File Book'), findsOneWidget);
    expect(find.text('No Chapters Book'), findsOneWidget);
  });

  testWidgets('opens a single-file book and plays it', (tester) async {
    await logInAndOpenLibrary(tester);

    await scrollAndTap(tester, find.text('Single File Book'));
    await pumpUntil(tester, find.byIcon(Icons.play_arrow));

    await tester.tap(find.byIcon(Icons.play_arrow));
    await pumpUntil(tester, find.byIcon(Icons.pause));
    // Seeded progress is 45s, inside "Chapter One" (0-60s). Titles use
    // TextScroll, which repeats overflowing text, so match on a substring.
    await pumpUntil(tester, find.textContaining('Chapter One'));
    expect(find.textContaining('Single File Book'), findsWidgets);
  });

  testWidgets(
    'shows title and chapter before playback starts',
    (tester) async {
      await logInAndOpenLibrary(tester);
      await scrollAndTap(tester, find.text('Single File Book'));
      await pumpUntil(tester, find.textContaining('Chapter One'));
    },
    skip: true, // Known bug: player only rebuilds on position changes.
  );

  testWidgets(
    'multi-file book keeps playing past the first file',
    (tester) async {
      await logInAndOpenLibrary(tester);
      await scrollAndTap(tester, find.text('Multi File Book'));
      await pumpUntil(tester, find.byIcon(Icons.play_arrow));
      // Part 1 is 0-45s; skipping to the next chapter must land in Part 2.
      await tester.tap(find.byIcon(Icons.skip_next));
      await pumpUntil(tester, find.textContaining('Part 2'));
    },
    skip: true, // Known bug: only the first audio file is ever loaded.
  );
}
