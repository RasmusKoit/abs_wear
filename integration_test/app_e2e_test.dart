// End-to-end tests against a real Audiobookshelf server.
//
// Run with tool/e2e.sh (it passes the server URL and credentials as
// --dart-define values read from tool/abs_test_server/.env).
import 'dart:async';
import 'dart:convert';

import 'package:abs_wear/app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

/// Keeps pumping frames for [duration] (animations need real frames).
Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Puts every test book back at 25% so each test starts from the same
/// server state (tests start sessions and sync progress).
Future<void> resetServerProgress() async {
  final login = await http.post(
    Uri.parse('$absUrl/login'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'username': absUser, 'password': absPassword}),
  );
  final user = (jsonDecode(login.body) as Map<String, dynamic>)['user'];
  final token = (user as Map<String, dynamic>)['token'] as String;
  final headers = {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };
  final libs = await http.get(
    Uri.parse('$absUrl/api/libraries'),
    headers: headers,
  );
  final libraries =
      (jsonDecode(libs.body) as Map<String, dynamic>)['libraries'] as List;
  for (final lib in libraries.cast<Map<String, dynamic>>()) {
    final items = await http.get(
      Uri.parse('$absUrl/api/libraries/${lib['id']}/items?limit=50'),
      headers: headers,
    );
    final results =
        (jsonDecode(items.body) as Map<String, dynamic>)['results'] as List;
    for (final item in results.cast<Map<String, dynamic>>()) {
      final media = item['media'] as Map<String, dynamic>;
      final duration = (media['duration'] as num).toDouble();
      await http.patch(
        Uri.parse('$absUrl/api/me/progress/${item['id']}'),
        headers: headers,
        body: jsonEncode({
          'duration': duration,
          'currentTime': (duration * 0.25).roundToDouble(),
          'progress': 0.25,
          'isFinished': false,
        }),
      );
    }
  }
}

/// Current server-side progress (seconds) of the book titled [title].
Future<double> serverProgress(String title) async {
  final login = await http.post(
    Uri.parse('$absUrl/login'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'username': absUser, 'password': absPassword}),
  );
  final user =
      (jsonDecode(login.body) as Map<String, dynamic>)['user']
          as Map<String, dynamic>;
  final headers = {'Authorization': 'Bearer ${user['token']}'};
  final me = await http.get(Uri.parse('$absUrl/api/me'), headers: headers);
  final progress =
      (jsonDecode(me.body) as Map<String, dynamic>)['mediaProgress'] as List;
  for (final p in progress.cast<Map<String, dynamic>>()) {
    final item = await http.get(
      Uri.parse('$absUrl/api/items/${p['libraryItemId']}'),
      headers: headers,
    );
    final media =
        (jsonDecode(item.body) as Map<String, dynamic>)['media']
            as Map<String, dynamic>;
    final meta = media['metadata'] as Map<String, dynamic>;
    if (meta['title'] == title) return (p['currentTime'] as num).toDouble();
  }
  return -1;
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
    await resetServerProgress();
  });

  testWidgets('backing out without playing keeps progress', (tester) async {
    await logInAndOpenLibrary(tester);
    await scrollAndTap(tester, find.text('Single File Book'));
    await pumpUntil(tester, find.textContaining('Chapter One'));
    await tester.binding.handlePopRoute();
    // Let the pop transition finish and the async session close land.
    await pumpUntil(tester, find.text('Continue Listening'));
    await pumpFor(tester, const Duration(seconds: 2));
    await scrollAndTap(tester, find.text('Single File Book'));
    // Still 45s in (Chapter One), not reset to 0 -> 00:00:15 left.
    await pumpUntil(tester, find.text('00:00:15'));
  });

  testWidgets('rejects a URL without a scheme', (tester) async {
    await tester.pumpWidget(const App());
    await pumpUntil(tester, find.text('Login'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server URL'),
      'abs.example.com',
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
    await pumpFor(tester, const Duration(seconds: 2));
    // Still on the form; an uncaught error would fail the test.
    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Hello $absUser'), findsNothing);
  });

  testWidgets('an expired token returns to the login form', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('serverUrl', absUrl);
    await prefs.setString('username', absUser);
    await prefs.setString('token', 'revoked-token');
    await prefs.setString('defaultLibraryId', 'any');
    await tester.pumpWidget(const App());
    await pumpUntil(tester, find.text('Hello $absUser'));
    await scrollAndTap(tester, find.widgetWithText(ElevatedButton, 'Library'));
    // The 401 pops the library and clears the token.
    await pumpUntil(tester, find.widgetWithText(TextFormField, 'Password'));
    expect(prefs.getString('token'), isNull);
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

  testWidgets('shows title and chapter before playback starts', (tester) async {
    await logInAndOpenLibrary(tester);
    await scrollAndTap(tester, find.text('Single File Book'));
    await pumpUntil(tester, find.textContaining('Chapter One'));
  });

  testWidgets('multi-file book keeps playing past the first file', (
    tester,
  ) async {
    await logInAndOpenLibrary(tester);
    await scrollAndTap(tester, find.text('Multi File Book'));
    await pumpUntil(tester, find.byIcon(Icons.play_arrow));
    // Part 1 is 0-45s; skipping to the next chapter must land in Part 2,
    // which lives in the second audio file.
    await pumpUntil(tester, find.textContaining('Part 1'));
    await tester.tap(find.byIcon(Icons.skip_next));
    await pumpUntil(tester, find.textContaining('Part 2'));
    await tester.tap(find.byIcon(Icons.skip_next));
    await pumpUntil(tester, find.textContaining('Part 3'));

    await tester.tap(find.byIcon(Icons.play_arrow));
    await pumpUntil(tester, find.byIcon(Icons.pause));
  });

  testWidgets('downloads a multi-file book with progress', (tester) async {
    await logInAndOpenLibrary(tester);
    await scrollAndTap(tester, find.text('Multi File Book'));
    await pumpUntil(tester, find.byIcon(Icons.play_arrow));

    // Play a few seconds past the seeded 34s position.
    await tester.tap(find.byIcon(Icons.play_arrow));
    await pumpUntil(tester, find.byIcon(Icons.pause));
    await pumpFor(tester, const Duration(seconds: 6));

    // Swipe to the controls page.
    await tester.fling(find.byType(PageView), const Offset(0, -300), 1000);
    await pumpUntil(tester, find.byIcon(Icons.download_rounded));

    await scrollAndTap(tester, find.byIcon(Icons.download_rounded));
    await pumpUntil(tester, find.byIcon(Icons.download_done_rounded));

    // Reloading sources after the download must not rewind progress.
    await pumpFor(tester, const Duration(seconds: 1));
    expect(await serverProgress('Multi File Book'), greaterThan(36));

    await scrollAndTap(tester, find.byIcon(Icons.delete_forever_rounded));
    await pumpUntil(tester, find.byIcon(Icons.download_rounded));
  });
}
