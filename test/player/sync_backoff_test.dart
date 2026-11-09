import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/helpers.dart';

const _server = 'http://abs.test';

/// Progress syncs of a paused player back off after failures, so a book
/// left open on a watch without network doesn't post every minute.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late List<String> requests;
  late List<int> answers;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_backoff_test');
    PathProviderPlatform.instance = FakePathProvider(root.path);
    requests = [];
    answers = [];
  });

  tearDown(() async {
    await AudioPlayerController.lastClose;
    root.deleteSync(recursive: true);
  });

  /// A paused player whose syncs get the status codes queued in [answers]
  /// (200 once they run out).
  AudioPlayerController controller() {
    final client = MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      final code = answers.isEmpty ? 200 : answers.removeAt(0);
      return http.Response(jsonEncode(const {}), code);
    });
    return AudioPlayerController(client: client)
      ..serverUrl = _server
      ..user = 'u'
      ..libraryItemId = 'li_1'
      ..sessionId = 's1'
      ..duration = 600;
  }

  test('a paused player with nothing new skips the periodic sync', () async {
    final c = controller();

    await c.periodicSync();
    expect(requests, isEmpty);

    // Moved while paused: sent.
    await c.seekToBookTime(100);
    await c.periodicSync();
    expect(requests, ['POST /api/session/s1/sync']);

    // Sent once; nothing new since.
    await c.periodicSync();
    expect(requests, hasLength(1));
    await c.close();
  });

  test('a failed sync holds off the periodic sync while paused', () async {
    answers = [500];
    final c = controller();

    await c.syncOpenSession(position: 10);
    expect(requests, hasLength(1));

    await c.seekToBookTime(100);
    await c.periodicSync();
    expect(requests, hasLength(1), reason: 'backing off');

    // A pause or close still syncs right away.
    await c.syncOpenSession();
    expect(requests, hasLength(2));
    await c.close();
  });

  test('a successful sync ends the backoff', () async {
    answers = [503];
    final c = controller();
    await c.syncOpenSession(position: 10);
    expect(c.retryAt, isNotNull);

    await c.syncOpenSession(position: 20);
    expect(c.retryAt, isNull);

    await c.seekToBookTime(100);
    await c.periodicSync();
    expect(requests, hasLength(3), reason: 'no longer backing off');
    await c.close();
  });

  test('a network error backs off like a server error', () async {
    final client = MockClient((request) async {
      requests.add(request.url.path);
      throw http.ClientException('Network is unreachable', request.url);
    });
    final c = AudioPlayerController(client: client)
      ..serverUrl = _server
      ..user = 'u'
      ..libraryItemId = 'li_1'
      ..sessionId = 's1'
      ..duration = 600;

    await c.syncOpenSession(position: 10);
    await c.seekToBookTime(100);
    await c.periodicSync();

    expect(requests, hasLength(1));
    expect(c.retryAt, isNotNull);
    await c.close();
  });

  test('the wait doubles from 2 minutes up to 30', () async {
    answers = [for (var i = 0; i < 7; i++) 500];
    final c = controller();
    final waits = <int>[];

    for (var i = 0; i < 7; i++) {
      final before = DateTime.now();
      await c.syncOpenSession(position: i.toDouble());
      // Rounded up: a few milliseconds pass during the sync.
      final wait = c.retryAt!.difference(before);
      waits.add((wait.inSeconds / 60).floor());
    }

    expect(waits, [2, 4, 8, 16, 30, 30, 30]);

    await c.syncOpenSession(position: 50);
    expect(c.retryAt, isNull);
    // Back to the shortest wait after the next failure.
    answers = [500];
    final before = DateTime.now();
    await c.syncOpenSession(position: 60);
    expect((c.retryAt!.difference(before).inSeconds / 60).floor(), 2);
    await c.close();
  });
}
