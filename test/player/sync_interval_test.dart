import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/helpers.dart';

const _server = 'http://abs.test';

/// While playing, progress is posted every 10 minutes and saved on the
/// watch in between; skips post once, shortly after the last one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late List<String> requests;
  late List<String> bodies;
  late Map<String, http.Response> answers;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_interval_test');
    PathProviderPlatform.instance = FakePathProvider(root.path);
    requests = [];
    bodies = [];
    answers = {};
  });

  tearDown(() async {
    await AudioPlayerController.lastClose;
    root.deleteSync(recursive: true);
  });

  final client = MockClient((request) async {
    final key = '${request.method} ${request.url.path}';
    requests.add(key);
    bodies.add(request.body);
    return answers[key] ?? http.Response(jsonEncode(const {}), 200);
  });

  AudioPlayerController controller() => AudioPlayerController(client: client)
    ..serverUrl = _server
    ..user = 'u'
    ..libraryItemId = 'li_1'
    ..sessionId = 's1'
    ..duration = 600
    ..chapters = const [
      BookChapter(start: 0, end: 300, title: 'One'),
      BookChapter(start: 300, end: 600, title: 'Two'),
    ];

  List<Map<String, dynamic>> progressFiles() {
    final dir = Directory('${root.path}/support/offline_progress');
    if (!dir.existsSync()) return const [];
    return [
      for (final f in dir.listSync().whereType<File>())
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    ];
  }

  test('playing posts every 10th tick and saves locally between', () async {
    final c = controller()..debugPlaying = true;

    for (var i = 1; i < AudioPlayerController.postEveryTicks; i++) {
      await c.seekToBookTime(i * 10);
      await c.periodicSync();
    }
    expect(requests, isEmpty);
    final saved = progressFiles().single;
    expect(saved, containsPair('pending', true));
    expect(saved, containsPair('currentTime', 90));

    await c.seekToBookTime(100);
    await c.periodicSync();
    expect(requests, ['POST /api/session/s1/sync']);
    expect(jsonDecode(bodies.single), containsPair('currentTime', 100));
    // Posted: nothing left pending for a book that isn't downloaded.
    expect(progressFiles(), isEmpty);

    // The count starts again after a post.
    await c.periodicSync();
    expect(requests, hasLength(1));
    c.debugPlaying = null;
    await c.close();
  });

  test('a pause or close post restarts the count', () async {
    final c = controller()..debugPlaying = true;
    for (var i = 0; i < 5; i++) {
      await c.periodicSync();
    }
    // As a pause does.
    await c.syncOpenSession();
    for (var i = 1; i < AudioPlayerController.postEveryTicks; i++) {
      await c.periodicSync();
    }
    expect(requests, hasLength(1));
    c.debugPlaying = null;
    await c.close();
  });

  test('a locally saved position reaches the server after a crash', () async {
    final c = controller()..debugPlaying = true;
    await c.seekToBookTime(120);
    await c.periodicSync();
    expect(requests, isEmpty);

    // The app was killed; the next start pushes what the player saved.
    answers['GET /api/me/progress/li_1'] = http.Response(
      jsonEncode({'currentTime': 30, 'lastUpdate': 1}),
      200,
    );
    await http.runWithClient(
      () => AudioPlayerController.pushLocalProgress(_server, 't', 'u'),
      () => client,
    );
    expect(requests, contains('PATCH /api/me/progress/li_1'));
    expect(jsonDecode(bodies.last), containsPair('currentTime', 120));
    expect(progressFiles().single, containsPair('pending', false));
  });

  test('a paused player still posts what is new each tick', () async {
    final c = controller();
    await c.seekToBookTime(100);
    await c.periodicSync();
    expect(requests, ['POST /api/session/s1/sync']);
    await c.close();
  });

  // In the fake zone; unawaited seeks move the position at once (no audio).
  test('rapid skips post once, a few seconds after the last', () {
    fakeAsync((async) {
      final c = controller();
      const twoSeconds = Duration(seconds: 2);
      unawaited(c.seekRelative(10));
      async.elapse(twoSeconds);
      unawaited(c.seekRelative(10));
      async.elapse(twoSeconds);
      unawaited(c.seekToNextChapter());
      async.elapse(twoSeconds);
      unawaited(c.seekRelative(-10));
      async.elapse(twoSeconds);
      expect(requests, isEmpty);

      async.elapse(AudioPlayerController.skipSyncDelay);
      expect(requests, ['POST /api/session/s1/sync']);
      expect(jsonDecode(bodies.single), containsPair('currentTime', 290));

      async.elapse(const Duration(seconds: 10));
      expect(requests, hasLength(1));

      // A chapter skip back posts too.
      unawaited(c.seekToPreviousChapter());
      async.elapse(AudioPlayerController.skipSyncDelay);
      expect(requests, hasLength(2));
      expect(jsonDecode(bodies.last), containsPair('currentTime', 0));
    });
  });

  test('a pause right after a skip posts once', () {
    fakeAsync((async) {
      final c = controller();
      unawaited(c.seekRelative(10));
      unawaited(c.syncOpenSession());
      async.elapse(const Duration(seconds: 10));
      expect(requests, hasLength(1));
    });
  });
}
