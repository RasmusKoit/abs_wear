// Times library loading on a real device. Run with tool/perf.sh.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/app/app.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/view/book_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

const absUrl = String.fromEnvironment('ABS_URL');
const absUser = String.fromEnvironment('ABS_TEST_USER');
const absPassword = String.fromEnvironment('ABS_TEST_PASSWORD');
const rounds = int.fromEnvironment('PERF_ROUNDS', defaultValue: 5);

/// Counts new connections and their connect + TLS time.
class _Connections extends HttpOverrides {
  int opened = 0;
  final List<int> setupMs = [];

  void reset() {
    opened = 0;
    setupMs.clear();
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        opened++;
        final watch = Stopwatch()..start();
        final task = uri.scheme == 'https'
            ? await SecureSocket.startConnect(uri.host, uri.port)
            : await Socket.startConnect(uri.host, uri.port);
        unawaited(
          task.socket.then(
            (_) => setupMs.add(watch.elapsedMilliseconds),
            onError: (_) {},
          ),
        );
        return task;
      };
  }
}

/// Pumps until [done] holds; returns the elapsed milliseconds.
Future<int> timeUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > timeout) {
      throw TimeoutException('Timed out after ${watch.elapsed}');
    }
    await tester.pump(const Duration(milliseconds: 10));
  }
  return watch.elapsedMilliseconds;
}

bool get coversDone =>
    PaintingBinding.instance.imageCache.pendingImageCount == 0;

Future<void> idle(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

int median(List<int> xs) => (List.of(xs)..sort())[xs.length ~/ 2];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final connections = _Connections();
  HttpOverrides.global = connections;

  testWidgets('library loading', (tester) async {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'dev.koit.abs_wear.channel.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationOngoing: true,
    );
    final login = await http.post(
      Uri.parse('$absUrl/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': absUser, 'password': absPassword}),
    );
    final token =
        ((jsonDecode(login.body) as Map<String, dynamic>)['user']
                as Map)['token']
            as String;
    final libraries = await http.get(
      Uri.parse('$absUrl/api/libraries'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final library = ((jsonDecode(libraries.body) as Map)['libraries'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((l) => l['mediaType'] == 'book');
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await prefs.setString('serverUrl', absUrl);
    await prefs.setString('username', absUser);
    await prefs.setString('token', token);
    await prefs.setString('defaultLibraryId', library['id'] as String);

    final results = <String, List<int>>{};
    void record(String name, int ms) {
      results.putIfAbsent('${name}_ms', () => []).add(ms);
      results
          .putIfAbsent('${name}_connections', () => [])
          .add(connections.opened);
      results
          .putIfAbsent('${name}_setup_ms', () => [])
          .addAll(connections.setupMs);
      connections.reset();
    }

    for (var round = 0; round < rounds; round++) {
      // Cold: no saved lists, no covers in memory, idle connections gone.
      await tester.pumpWidget(const SizedBox());
      await JsonCache.idle;
      await JsonCache.clear();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await idle(tester, const Duration(seconds: 20));
      connections.reset();

      await tester.pumpWidget(const App());
      await timeUntil(
        tester,
        () => find.text('Hello $absUser').evaluate().isNotEmpty,
      );
      // Someone reading the home screen.
      await idle(tester, const Duration(seconds: 2));
      connections.reset();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Library'));
      record(
        'library',
        await timeUntil(
          tester,
          () => find.byIcon(Icons.refresh).evaluate().isNotEmpty && coversDone,
        ),
      );

      await idle(tester, const Duration(seconds: 2));
      await tester.ensureVisible(find.text('All books'));
      await tester.pump();
      connections.reset();
      await tester.tap(find.text('All books'));
      record(
        'browse',
        await timeUntil(
          tester,
          () =>
              find.textContaining(' books').evaluate().isNotEmpty &&
              find.byType(BookTile).evaluate().isNotEmpty &&
              coversDone,
        ),
      );

      // Back after a while: saved list, covers no longer in memory.
      await tester.binding.handlePopRoute();
      await idle(tester, const Duration(seconds: 10));
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await tester.ensureVisible(find.text('All books'));
      await tester.pump();
      connections.reset();
      await tester.tap(find.text('All books'));
      record(
        'browse_again',
        await timeUntil(
          tester,
          () => find.byType(BookTile).evaluate().isNotEmpty && coversDone,
        ),
      );
      await tester.binding.handlePopRoute();
      await tester.pump();

      // Reopened app: saved lists, no covers in memory, no connections.
      await tester.pumpWidget(const SizedBox());
      await idle(tester, const Duration(seconds: 20));
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await tester.pumpWidget(const App());
      await timeUntil(
        tester,
        () => find.text('Hello $absUser').evaluate().isNotEmpty,
      );
      await idle(tester, const Duration(seconds: 2));
      connections.reset();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Library'));
      record(
        'reopen_library',
        await timeUntil(
          tester,
          () => find.byIcon(Icons.refresh).evaluate().isNotEmpty && coversDone,
        ),
      );
      await idle(tester, const Duration(seconds: 2));
      await tester.ensureVisible(find.text('All books'));
      await tester.pump();
      connections.reset();
      await tester.tap(find.text('All books'));
      record(
        'reopen_browse',
        await timeUntil(
          tester,
          () => find.byType(BookTile).evaluate().isNotEmpty && coversDone,
        ),
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
    }

    binding.reportData = {
      for (final e in results.entries) e.key: e.value,
      for (final e in results.entries)
        if (e.value.isNotEmpty) '${e.key}_median': median(e.value),
    };
  }, timeout: const Timeout(Duration(minutes: 30)));
}
