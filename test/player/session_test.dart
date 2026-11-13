import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:abs_wear/login/data/auth_session.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:abs_wear/player/darts/download_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => '$path/support';
}

const _deviceInfo = MethodChannel('dev.fluttercommunity.plus/device_info');

/// What device_info_plus reads from android.os.Build.
const _androidBuild = <String, Object?>{
  'version': {
    'baseOS': '',
    'codename': 'REL',
    'incremental': '1',
    'previewSdkInt': 0,
    'release': '16',
    'sdkInt': 36,
    'securityPatch': '2026-10-01',
  },
  'board': 'test',
  'bootloader': 'test',
  'brand': 'test',
  'device': 'test',
  'display': 'test',
  'fingerprint': 'test',
  'hardware': 'test',
  'host': 'test',
  'id': 'test',
  'manufacturer': 'test',
  'model': 'test',
  'product': 'test',
  'name': 'test',
  'supported32BitAbis': <String>[],
  'supported64BitAbis': <String>[],
  'supportedAbis': <String>[],
  'tags': 'release-keys',
  'time': 0,
  'type': 'user',
  'isPhysicalDevice': false,
  'freeDiskSize': 0,
  'totalDiskSize': 0,
  'systemFeatures': <String>[],
  'isLowRamDevice': false,
  'physicalRamSize': 0,
  'availableRamSize': 0,
};

const _server = 'http://abs.test';

/// /play requests that wait until the test answers them.
class _Plays {
  final started = <Completer<http.Response>>[];
  int _inFlight = 0;

  /// The most /play requests waiting for an answer at once.
  int maxInFlight = 0;

  Future<http.Response> call() {
    final play = Completer<http.Response>();
    started.add(play);
    maxInFlight = max(maxInFlight, ++_inFlight);
    return play.future.whenComplete(() => _inFlight--);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late List<String> requests;
  late List<String> bodies;
  late Map<String, Future<http.Response> Function()> routes;
  late http.Client client;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('abs_session_test');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_deviceInfo, (call) async => _androidBuild);
    requests = [];
    bodies = [];
    routes = {};
    client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      requests.add(key);
      bodies.add(request.body);
      return await routes[key]?.call() ?? http.Response('', 404);
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_deviceInfo, null);
    // Lets closes land before the next test reuses the static state.
    await AudioPlayerController.lastClose;
    docs.deleteSync(recursive: true);
  });

  http.Response ok([Object body = const {}]) =>
      http.Response(jsonEncode(body), 200);

  AudioPlayerController controller() => AudioPlayerController(client: client)
    ..serverUrl = _server
    ..user = 'u'
    ..libraryItemId = 'li_1'
    ..sessionId = 's1'
    ..duration = 600;

  _Plays playsQueue() {
    final plays = _Plays();
    routes['POST /api/items/li_1/play'] = plays.call;
    return plays;
  }

  /// Pending progress files the player wrote.
  List<Map<String, dynamic>> pendingFiles() {
    final dir = Directory('${docs.path}/support/offline_progress');
    if (!dir.existsSync()) return const [];
    return [
      for (final f in dir.listSync().whereType<File>())
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    ].where((json) => json['pending'] == true).toList();
  }

  group('a session the server forgot (404)', () {
    test('a sync starts a new session and resends to it', () async {
      routes['POST /api/items/li_1/play'] = () async => ok({
        'id': 's2',
        // Ignored: the player keeps its own position and audio.
        'currentTime': 5,
        'duration': 1,
        'audioTracks': <Object>[],
      });
      routes['POST /api/session/s2/sync'] = () async => ok();
      final c = controller();

      await c.syncOpenSession(position: 42);

      expect(requests, [
        'POST /api/session/s1/sync',
        'POST /api/items/li_1/play',
        'POST /api/session/s2/sync',
      ]);
      expect(c.sessionId, 's2');
      expect(bodies[2], bodies[0]);
      expect(jsonDecode(bodies[2]), containsPair('currentTime', 42));
      final play = jsonDecode(bodies[1]) as Map<String, dynamic>;
      expect(play['deviceInfo'], containsPair('clientName', 'ABS Wear'));
      expect(c.duration, 600);
      expect(pendingFiles(), isEmpty);

      // Later syncs go straight to the new session.
      await c.syncOpenSession(position: 50);
      expect(requests.last, 'POST /api/session/s2/sync');
      expect(requests.where((r) => r.contains('/play')), hasLength(1));
      await c.close();
    });

    test('listening during the restart goes to the next sync', () async {
      final play = Completer<http.Response>();
      routes['POST /api/items/li_1/play'] = () => play.future;
      routes['POST /api/session/s2/sync'] = () async => ok();
      final c = controller()..listenClock.start();

      final sync = c.syncOpenSession(position: 42);
      // Still listening while the restart waits for the server.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final restarted = c.listenClock.elapsed.inMicroseconds / 1e6;
      play.complete(ok({'id': 's2'}));
      await sync;
      c.listenClock.stop();
      await c.syncOpenSession(position: 43);

      double listened(int i) =>
          (jsonDecode(bodies[i]) as Map<String, dynamic>)['timeListened']
              as double;
      // The resend repeats the first body; the time since is in the next.
      expect(bodies[2], bodies[0]);
      expect(restarted - listened(0), greaterThan(0.05));
      expect(
        listened(3),
        greaterThanOrEqualTo(restarted - listened(0) - 0.001),
      );
      // Each body counts whole milliseconds: allow 1 ms each.
      expect(
        listened(0) + listened(3),
        closeTo(c.listenClock.elapsed.inMicroseconds / 1e6, 0.002),
      );
      await c.close();
    });

    test('an episode session is started for the episode', () async {
      routes['POST /api/items/li_1/play/ep_1'] = () async => ok({'id': 's2'});
      routes['POST /api/session/s2/sync'] = () async => ok();
      final c = controller()..episodeId = 'ep_1';

      await c.syncOpenSession(position: 42);

      expect(requests, contains('POST /api/items/li_1/play/ep_1'));
      expect(c.sessionId, 's2');
      await c.close();
    });

    test('a failed restart is tried once and then backs off', () async {
      routes['POST /api/items/li_1/play'] = () async => http.Response('', 500);
      final c = controller();

      await c.syncOpenSession(position: 42);

      expect(requests, [
        'POST /api/session/s1/sync',
        'POST /api/items/li_1/play',
      ]);
      expect(c.sessionId, 's1');
      expect(pendingFiles().single['currentTime'], 42);
      // Paused, the next periodic sync waits for the backoff.
      await c.periodicSync();
      expect(requests, hasLength(2));
      await c.close();
    });

    test('no restart once the player is closing', () async {
      final sync = Completer<http.Response>();
      routes['POST /api/session/s1/sync'] = () => sync.future;
      final c = controller()..isLoaded = true;

      unawaited(c.syncOpenSession(position: 42));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      unawaited(http.runWithClient(c.close, () => client));
      sync.complete(http.Response('', 404));
      await AudioPlayerController.lastClose;

      expect(requests, [
        'POST /api/session/s1/sync',
        'POST /api/session/s1/close',
      ]);
      expect(pendingFiles(), hasLength(1));
    });

    test('a restart that lands after the close drops its session', () async {
      final play = Completer<http.Response>();
      routes['POST /api/items/li_1/play'] = () => play.future;
      routes['POST /api/session/s3/close'] = () async => ok();
      final c = controller()..isLoaded = true;

      unawaited(
        http.runWithClient(() => c.syncOpenSession(position: 42), () => client),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      unawaited(http.runWithClient(c.close, () => client));
      play.complete(ok({'id': 's3'}));
      await AudioPlayerController.lastClose;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c.sessionId, 's1');
      expect(requests, contains('POST /api/session/s3/close'));
      expect(requests, contains('POST /api/session/s1/close'));
      expect(requests, isNot(contains('POST /api/session/s3/sync')));
    });

    test('a close keeps the position for pushLocalProgress', () async {
      final c = controller()..isLoaded = true;
      await http.runWithClient(c.close, () => client);

      expect(requests, ['POST /api/session/s1/close']);
      expect(pendingFiles(), hasLength(1));
    });
  });

  group('reloadSources', () {
    const m4b = BookTrack(
      index: 1,
      startOffset: 0,
      duration: 600,
      contentUrl: '/api/items/li_1/file/111',
      filename: 'book.m4b',
      ino: '111',
      size: 1000,
    );
    final hlsSession = {
      'id': 's2',
      'audioTracks': [
        {
          'index': 1,
          'startOffset': 0,
          'duration': 600,
          'contentUrl': '/hls/s2/output.m3u8',
        },
      ],
    };

    setUp(() {
      routes['POST /api/session/s1/sync'] = () async => ok();
      routes['POST /api/session/s1/close'] = () async => ok();
      routes['POST /api/session/s2/sync'] = () async => ok();
    });

    test('closes the old session only after the new stream started', () async {
      routes['POST /api/items/li_1/play'] = () async => ok(hlsSession);
      routes['HEAD /hls/s2/output-0.ts'] = () async => ok();
      final c = controller()..tracks = const [m4b];

      await http.runWithClient(c.deleteDownload, () => client);

      expect(c.sessionId, 's2');
      expect(
        requests,
        containsAllInOrder([
          'POST /api/items/li_1/play',
          'POST /api/session/s1/close',
        ]),
      );
      await c.close();
    });

    test('keeps the old, still open session when /play fails', () async {
      routes['POST /api/items/li_1/play'] = () async => http.Response('', 500);
      final c = controller()..tracks = const [m4b];

      await http.runWithClient(c.deleteDownload, () => client);

      expect(c.sessionId, 's1');
      expect(requests, isNot(contains('POST /api/session/s1/close')));
      await c.syncOpenSession(position: 10);
      expect(requests.last, 'POST /api/session/s1/sync');
      await c.close();
    });

    test(
      "a 404 restart doesn't start a session once a reopen replaced it",
      () async {
        final plays = playsQueue();
        final sync = Completer<http.Response>();
        routes['POST /api/session/s1/sync'] = () => sync.future;
        routes['HEAD /hls/s2/output-0.ts'] = () async => ok();
        final c = controller()..tracks = const [m4b];

        final reload = http.runWithClient(c.deleteDownload, () => client);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(plays.started, hasLength(1), reason: 'the stream reopen');
        // The reload's sync to the old session 404s while the reopen's
        // /play is in flight: the restart waits for it.
        sync.complete(http.Response('', 404));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(plays.started, hasLength(1), reason: 'the restart waits');
        plays.started[0].complete(ok(hlsSession));
        await reload;
        await c.syncOpenSession(position: 10);

        // The restart found the session replaced and resent to it.
        expect(plays.started, hasLength(1));
        expect(plays.maxInFlight, 1);
        expect(c.sessionId, 's2');
        expect(
          requests.where((r) => r == 'POST /api/session/s2/sync'),
          hasLength(2),
        );
        await c.close();
      },
    );

    test('a stream reopen waits for a running 404 restart', () async {
      final plays = playsQueue();
      routes['POST /api/session/s1/sync'] = () async => http.Response('', 404);
      routes['POST /api/session/s3/sync'] = () async => ok();
      routes['POST /api/session/s3/close'] = () async => ok();
      routes['HEAD /hls/s2/output-0.ts'] = () async => ok();
      final c = controller()..tracks = const [m4b];

      unawaited(
        http.runWithClient(() => c.syncOpenSession(position: 0), () => client),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(plays.started, hasLength(1), reason: 'the restart');
      final reload = http.runWithClient(c.deleteDownload, () => client);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(plays.started, hasLength(1), reason: 'the reopen waits');

      plays.started[0].complete(ok({'id': 's3'}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(plays.started, hasLength(2));
      plays.started[1].complete(ok(hlsSession));
      await reload;

      expect(plays.maxInFlight, 1);
      expect(c.sessionId, 's2');
      expect(
        requests,
        containsAllInOrder([
          'POST /api/session/s3/sync',
          'POST /api/session/s3/close',
        ]),
      );
      await c.close();
    });

    test('loads at a seek made while it reloads', () async {
      final play = Completer<http.Response>();
      routes['POST /api/items/li_1/play'] = () => play.future;
      routes['HEAD /hls/s2/output-50.ts'] = () async => ok();
      final c = controller()..tracks = const [m4b];

      final reload = http.runWithClient(c.deleteDownload, () => client);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await c.seekToBookTime(300);
      play.complete(ok(hlsSession));
      await reload;

      // The stream is awaited (and loaded) at the seek, not where the
      // reload started.
      expect(requests, contains('HEAD /hls/s2/output-50.ts'));
      expect(requests, isNot(contains('HEAD /hls/s2/output-0.ts')));
      expect(c.bookPosition, 300);
      await c.close();
    });
  });

  group('a player that started offline', () {
    /// Played offline at 50 s, the server's session at 100 s.
    Future<AudioPlayerController> offline() async {
      final c = controller()
        ..sessionId = ''
        ..isOffline = true;
      await c.seekToBookTime(50);
      return c;
    }

    void serverAt(int lastUpdate) {
      routes['POST /api/items/li_1/play'] = () async =>
          ok({'id': 's2', 'currentTime': 100});
      routes['GET /api/me/progress/li_1'] = () async =>
          ok({'currentTime': 20, 'lastUpdate': lastUpdate});
      routes['POST /api/session/s2/sync'] = () async => ok();
      routes['POST /api/session/s2/close'] = () async => ok();
    }

    test('goes online and sends newer offline progress', () async {
      serverAt(DateTime.now().millisecondsSinceEpoch - 60000);
      final c = await offline();

      await c.periodicSync();

      expect(c.isOffline, isFalse);
      expect(c.sessionId, 's2');
      expect(
        jsonDecode(bodies[requests.lastIndexOf('POST /api/session/s2/sync')]),
        containsPair('currentTime', 50),
      );
      expect(pendingFiles(), isEmpty);
      await http.runWithClient(c.close, () => client);
    });

    test('goes online and moves to newer server progress', () async {
      serverAt(DateTime.now().millisecondsSinceEpoch + 60000);
      final c = await offline();

      await c.periodicSync();

      expect(c.isOffline, isFalse);
      expect(c.bookPosition, 20);
      expect(requests, isNot(contains('POST /api/session/s2/sync')));
      await http.runWithClient(c.close, () => client);
    });

    test('a failed /play keeps progress on the watch and backs off', () async {
      routes['POST /api/items/li_1/play'] = () async => http.Response('', 500);
      final c = await offline();

      await c.periodicSync();
      expect(c.isOffline, isTrue);
      expect(c.retryAt, isNotNull);
      expect(pendingFiles().single['currentTime'], 50);

      await c.periodicSync();
      expect(requests.where((r) => r.contains('/play')), hasLength(1));
      await c.close();
    });

    test('a /play that times out has its late session closed', () async {
      final saved = AudioPlayerController.reconnectTimeout;
      AudioPlayerController.reconnectTimeout = const Duration(milliseconds: 50);
      addTearDown(() => AudioPlayerController.reconnectTimeout = saved);
      final play = Completer<http.Response>();
      routes['POST /api/items/li_1/play'] = () => play.future;
      routes['POST /api/session/s9/close'] = () async => ok();
      final c = await offline();

      await http.runWithClient(c.periodicSync, () => client);
      expect(c.isOffline, isTrue);
      play.complete(ok({'id': 's9'}));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(requests, contains('POST /api/session/s9/close'));
      expect(
        jsonDecode(bodies[requests.indexOf('POST /api/session/s9/close')]),
        isEmpty,
      );
      expect(c.sessionId, isEmpty);
      await c.close();
    });

    test(
      "an untouched download's cached position doesn't beat the server's",
      () async {
        final dir = Directory('${docs.path}/li_1')..createSync();
        File('${dir.path}/001_111.mp3').writeAsStringSync('');
        File('${dir.path}/session.json').writeAsStringSync(
          jsonEncode({
            'duration': 600,
            'currentTime': 30,
            'audioTracks': [
              {
                'index': 1,
                'startOffset': 0,
                'duration': 600,
                'contentUrl': '/api/items/li_1/file/111',
                'metadata': {'filename': 'a.mp3'},
                'mimeType': 'audio/mpeg',
              },
            ],
          }),
        );
        // No local progress file; the server's is older than today.
        routes['POST /api/items/li_1/play'] = () async =>
            http.Response('', 500);
        final c = AudioPlayerController(client: client);
        expect(
          await c.setupPlayer('li_1', _server, 't', userName: 'u'),
          isTrue,
        );
        expect(c.isOffline, isTrue);
        expect(c.bookPosition, 30);

        routes['POST /api/items/li_1/play'] = () async =>
            ok({'id': 's2', 'currentTime': 100});
        routes['GET /api/me/progress/li_1'] = () async => ok({
          'currentTime': 100,
          'lastUpdate': DateTime.now().millisecondsSinceEpoch - 60000,
        });
        routes['POST /api/session/s2/sync'] = () async => ok();
        routes['POST /api/session/s2/close'] = () async => ok();
        await c.periodicSync();

        expect(c.isOffline, isFalse);
        expect(c.bookPosition, 100);
        expect(requests, isNot(contains('POST /api/session/s2/sync')));
        await http.runWithClient(c.close, () => client);
      },
    );

    test('keeps its download', () async {
      final c = await offline();
      final dir = Directory(await c.localDirPath())..createSync();
      File('${dir.path}/session.json').writeAsStringSync('{}');

      await c.deleteDownload();

      expect(dir.existsSync(), isTrue);
      await c.close();
    });
  });

  group('closing', () {
    test('a book still downloading keeps its closing position', () async {
      routes['POST /api/session/s1/close'] = () async => ok();
      final job = DownloadJob(
        key: 'li_1',
        dir: '${docs.path}/li_1',
        title: 'Book',
        serverUrl: _server,
        token: 't',
        libraryItemId: 'li_1',
        tracks: const [
          BookTrack(
            index: 1,
            startOffset: 0,
            duration: 600,
            contentUrl: '/api/items/li_1/file/111',
            filename: 'book.mp3',
            ino: '111',
            size: 1000,
          ),
        ],
        hasCover: false,
        sessionMeta: null,
        client: MockClient.streaming(
          (_, _) => Completer<http.StreamedResponse>().future,
        ),
      );
      final result = DownloadManager.instance.enqueue(job);
      addTearDown(() async {
        DownloadManager.instance.cancel('li_1');
        await result;
      });
      final c = controller()..isLoaded = true;

      await c.syncOpenSession(close: true, position: 250);

      final key = '$_server|u|li_1'.hashCode.toUnsigned(32);
      final file = File('${docs.path}/support/offline_progress/$key.json');
      expect(file.existsSync(), isTrue, reason: 'offline play resumes here');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(json['currentTime'], 250);
      expect(json['pending'], isFalse);
    });

    test('the next player waits for every earlier close', () async {
      final slow = Completer<http.Response>();
      routes['POST /api/session/a/close'] = () => slow.future;
      routes['POST /api/session/b/close'] = () async => ok();
      final a = controller()
        ..sessionId = 'a'
        ..isLoaded = true;
      final b = controller()
        ..sessionId = 'b'
        ..isLoaded = true;

      unawaited(a.close());
      unawaited(b.close());
      var done = false;
      unawaited(AudioPlayerController.lastClose.then((_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requests, contains('POST /api/session/b/close'));
      expect(done, isFalse, reason: "a's final save hasn't landed");

      slow.complete(ok());
      await AudioPlayerController.lastClose;
      expect(done, isTrue);
    });

    test(
      "an old player closing doesn't unregister the reopened book",
      () async {
        routes['POST /api/items/li_1/play'] = () async =>
            http.Response('', 401);
        routes['GET /api/me/progress/li_1'] = () async =>
            http.Response('', 404);
        routes['PATCH /api/me/progress/li_1'] = () async => ok();
        Future<void> push() => http.runWithClient(
          () => AudioPlayerController.pushLocalProgress(_server, 't', 'u'),
          () => client,
        );

        // The same book opened twice: the second player registers before
        // the first one closed.
        final old = AudioPlayerController(client: client);
        final reopened = AudioPlayerController(client: client);
        await old.setupPlayer('li_1', _server, 't', userName: 'u');
        await reopened.setupPlayer('li_1', _server, 't', userName: 'u');
        // Progress the open player saved (offline, so it stays pending).
        reopened.isOffline = true;
        await reopened.syncOpenSession(position: 42);
        expect(pendingFiles(), hasLength(1));

        await old.close();
        await push();
        expect(
          requests.where((r) => r.contains('/api/me/progress')),
          isEmpty,
          reason: 'the book is still open in a player',
        );

        await reopened.close();
        await push();
        expect(requests, contains('PATCH /api/me/progress/li_1'));
      },
    );
  });

  group('checking offline progress against the server', () {
    final updatedAt = DateTime.now().millisecondsSinceEpoch - 60000;

    File progressFile() {
      final key = '$_server|u|li_1'.hashCode.toUnsigned(32);
      return File('${docs.path}/support/offline_progress/$key.json');
    }

    /// Progress from offline play: position 50, 30 s listened.
    void writePending() {
      progressFile()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'server': _server,
            'user': 'u',
            'itemId': 'li_1',
            'duration': 600,
            'currentTime': 50,
            'listenedMs': 30000,
            'updatedAt': updatedAt,
            'pending': true,
          }),
        );
    }

    Map<String, dynamic> progress() =>
        jsonDecode(progressFile().readAsStringSync()) as Map<String, dynamic>;

    Future<void> push() => http.runWithClient(
      () => AudioPlayerController.pushLocalProgress(_server, 't', 'u'),
      () => client,
    );

    final mp3Session = {
      'id': 's1',
      'currentTime': 100,
      'duration': 600,
      'audioTracks': [
        {
          'index': 1,
          'startOffset': 0,
          'duration': 600,
          'contentUrl': '/api/items/li_1/file/111',
          'mimeType': 'audio/mpeg',
        },
      ],
    };

    test('a check that fails once is retried before resuming', () async {
      writePending();
      routes['POST /api/items/li_1/play'] = () async => ok(mp3Session);
      final answers = [
        http.Response('', 504),
        // Played elsewhere since the offline progress was saved.
        ok({'currentTime': 100, 'lastUpdate': updatedAt + 1000}),
      ];
      routes['GET /api/me/progress/li_1'] = () async => answers.removeAt(0);
      routes['POST /api/session/s1/sync'] = () async => ok();
      routes['POST /api/session/s1/close'] = () async => ok();
      final c = AudioPlayerController(client: client);

      expect(await c.setupPlayer('li_1', _server, 't', userName: 'u'), isTrue);

      expect(answers, isEmpty);
      expect(c.bookPosition, 100, reason: 'the newer server position wins');
      await http.runWithClient(c.close, () => client);
    });

    group('when the check fails at open', () {
      late List<http.Response> answers;

      /// Opens the book with every progress check failing until [answers]
      /// has some.
      Future<AudioPlayerController> open() async {
        writePending();
        routes['POST /api/items/li_1/play'] = () async => ok(mp3Session);
        answers = [];
        routes['GET /api/me/progress/li_1'] = () async =>
            answers.isEmpty ? http.Response('', 504) : answers.removeAt(0);
        routes['POST /api/session/s1/sync'] = () async => ok();
        routes['POST /api/session/s1/close'] = () async => ok();
        final c = AudioPlayerController(client: client);
        expect(
          await c.setupPlayer('li_1', _server, 't', userName: 'u'),
          isTrue,
        );
        return c;
      }

      Map<String, dynamic> lastBody(String request) =>
          jsonDecode(bodies[requests.lastIndexOf(request)])
              as Map<String, dynamic>;

      test(
        'resumes offline but sends nothing, closing without progress',
        () async {
          final c = await open();
          expect(c.bookPosition, 50, reason: 'where the watch was');
          expect(requests, isNot(contains('POST /api/session/s1/sync')));

          await http.runWithClient(c.close, () => client);
          // An empty close leaves the server's progress untouched (even a
          // finished book's, whose session starts at 0).
          expect(lastBody('POST /api/session/s1/close'), isEmpty);
          // Still pending, unchanged: a later push compares the times.
          expect(progress(), containsPair('pending', true));
          expect(progress(), containsPair('updatedAt', updatedAt));
          expect(progress(), containsPair('currentTime', 50));
        },
      );

      test('a later answer with newer server progress moves there', () async {
        final c = await open();
        // Played elsewhere after the offline listening, further back.
        answers.add(ok({'currentTime': 20, 'lastUpdate': updatedAt + 1000}));
        await c.periodicSync();
        expect(c.bookPosition, 20);
        // Offline listening time is still reported.
        expect(lastBody('POST /api/session/s1/sync'), {
          'currentTime': 20,
          'timeListened': 30,
          'duration': 600,
        });
        await http.runWithClient(c.close, () => client);
      });

      test('a later answer with older server progress sends the offline '
          'position', () async {
        final c = await open();
        answers.add(ok({'currentTime': 100, 'lastUpdate': updatedAt - 1000}));
        await c.periodicSync();
        expect(c.bookPosition, 50);
        expect(
          lastBody('POST /api/session/s1/sync'),
          containsPair('currentTime', 50),
        );
        await http.runWithClient(c.close, () => client);
      });

      test('a seek on the watch makes its progress the latest', () async {
        final c = await open();
        await c.seekToBookTime(60);
        final checks = requests
            .where((r) => r == 'GET /api/me/progress/li_1')
            .length;
        // Newer server progress no longer matters: the seek is newer.
        answers.add(ok({'currentTime': 20, 'lastUpdate': updatedAt + 1000}));
        await c.periodicSync();
        expect(
          requests.where((r) => r == 'GET /api/me/progress/li_1').length,
          checks,
        );
        expect(
          lastBody('POST /api/session/s1/sync'),
          containsPair('currentTime', 60),
        );
        expect(c.bookPosition, 60);
        await http.runWithClient(c.close, () => client);
      });

      test('still no answer: keeps waiting, asking with backoff', () async {
        final c = await open();
        int checks() =>
            requests.where((r) => r == 'GET /api/me/progress/li_1').length;
        final before = checks();
        await c.periodicSync();
        expect(checks(), before + 1);
        expect(c.retryAt, isNotNull);
        // Within the backoff: not asked again.
        await c.periodicSync();
        expect(checks(), before + 1);
        expect(requests, isNot(contains('POST /api/session/s1/sync')));
        expect(c.bookPosition, 50);
        await http.runWithClient(c.close, () => client);
      });
    });

    test("a push doesn't send it when the check fails", () async {
      writePending();
      routes['PATCH /api/me/progress/li_1'] = () async => ok();

      routes['GET /api/me/progress/li_1'] = () async => http.Response('', 502);
      await push();
      routes['GET /api/me/progress/li_1'] = () async =>
          throw http.ClientException('timeout');
      await push();
      expect(requests, isNot(contains('PATCH /api/me/progress/li_1')));
      expect(progress(), containsPair('pending', true));

      // Retried on the next push; the server has no progress (404).
      routes['GET /api/me/progress/li_1'] = () async => http.Response('', 404);
      await push();
      expect(requests, contains('PATCH /api/me/progress/li_1'));
      expect(jsonDecode(bodies.last), containsPair('currentTime', 50));
      expect(progress(), containsPair('pending', false));
    });

    test('a stale download reopens an MP4 book as a stream', () async {
      // Downloaded as MP3, since converted to m4b on the server.
      writePending();
      routes['GET /api/me/progress/li_1'] = () async => http.Response('', 404);
      final dir = Directory('${docs.path}/li_1')..createSync();
      File('${dir.path}/session.json').writeAsStringSync('{}');
      final plays = <Map<String, dynamic>>[];
      routes['POST /api/items/li_1/play'] = () async {
        plays.add(jsonDecode(bodies.last) as Map<String, dynamic>);
        return plays.length == 1
            ? ok({
                'id': 's1',
                'currentTime': 100,
                'duration': 600,
                'audioTracks': [
                  {
                    'index': 1,
                    'startOffset': 0,
                    'duration': 600,
                    'contentUrl': '/api/items/li_1/file/222',
                    'mimeType': 'audio/mp4',
                  },
                ],
              })
            : ok({
                'id': 's2',
                'audioTracks': [
                  {
                    'index': 1,
                    'startOffset': 0,
                    'duration': 600,
                    'contentUrl': '/hls/s2/output.m3u8',
                  },
                ],
              });
      };
      routes['POST /api/session/s1/close'] = () async => ok();
      routes['POST /api/session/s2/close'] = () async => ok();
      routes['POST /api/session/s2/sync'] = () async => ok();
      routes['HEAD /hls/s2/output-8.ts'] = () async => ok();
      final c = AudioPlayerController(client: client);

      final started = await http.runWithClient(
        () => c.setupPlayer('li_1', _server, 't', userName: 'u'),
        () => client,
      );

      expect(started, isTrue);
      expect(plays, hasLength(2));
      expect(plays[0], containsPair('forceDirectPlay', true));
      expect(plays[1], isNot(contains('forceDirectPlay')));
      expect(c.sessionId, 's2');
      // The old session closes leaving the server's progress as it is; the
      // stream loads at the newer offline one (50 s is in segment 8).
      final close = bodies[requests.indexOf('POST /api/session/s1/close')];
      expect(jsonDecode(close), isEmpty);
      expect(requests, contains('HEAD /hls/s2/output-8.ts'));
      expect(c.bookPosition, 50);
      await http.runWithClient(c.close, () => client);
    });
  });

  group('stream token', () {
    final now = DateTime(2026, 11, 13, 12);
    final auth = AuthSession.instance;

    /// A JWT (unsigned, the app never checks signatures) expiring at [exp].
    String jwt(String id, DateTime exp) {
      String part(Object json) =>
          base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
      final seconds = exp.millisecondsSinceEpoch ~/ 1000;
      final payload = part({'jti': id, 'exp': seconds});
      return '${part({'alg': 'HS256'})}.$payload.sig';
    }

    final old = jwt('old', now.add(const Duration(hours: 1)));
    final renewed = jwt('new', now.add(const Duration(hours: 2)));
    final mp3Session = {
      'id': 's1',
      'currentTime': 100,
      'duration': 600,
      'audioTracks': [
        {
          'index': 1,
          'startOffset': 0,
          'duration': 600,
          'contentUrl': '/api/items/li_1/file/111',
          'mimeType': 'audio/mpeg',
        },
      ],
    };

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      auth
        ..start(_server, old, 'ref1')
        ..clock = () => now;
      routes['POST /api/items/li_1/play'] = () async => ok(mp3Session);
      routes['POST /api/session/s1/sync'] = () async => ok();
      routes['POST /api/session/s1/close'] = () async => ok();
      routes['POST /auth/refresh'] = () async => ok({
        'user': {'accessToken': renewed, 'refreshToken': 'ref2'},
      });
    });

    tearDown(() {
      auth
        ..clear()
        ..clock = DateTime.now;
    });

    Future<AudioPlayerController> open(String token) async {
      final c = AudioPlayerController(client: client);
      expect(
        await c.setupPlayer('li_1', _server, token, userName: 'u'),
        isTrue,
      );
      return c;
    }

    /// Waits (briefly) until [done] holds.
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('direct-play streams schedule a renewal before expiry', () async {
      final c = await open(old);

      expect(c.sourceToken, old);
      expect(c.renewalScheduled, isTrue);
      await http.runWithClient(c.close, () => client);
      expect(c.renewalScheduled, isFalse);
    });

    test('a legacy token is never renewed', () async {
      auth.start(_server, 'legacy', null);
      final c = await open('legacy');

      expect(c.sourceToken, 'legacy');
      expect(c.renewalScheduled, isFalse);
      await http.runWithClient(c.close, () => client);
    });

    test('renewal refreshes and reloads at the same position', () async {
      final c = await open(old);
      auth.clock = () => now.add(const Duration(minutes: 59));

      await http.runWithClient(c.debugRenewSources, () => client);

      expect(requests, contains('POST /auth/refresh'));
      expect(c.sourceToken, renewed);
      expect(c.bookPosition, 100);
      expect(c.renewalScheduled, isTrue, reason: 'for the new token');
      await http.runWithClient(c.close, () => client);
    });

    test('renewal does nothing while the token has time left', () async {
      final c = await open(old);

      await http.runWithClient(c.debugRenewSources, () => client);

      expect(requests, isNot(contains('POST /auth/refresh')));
      expect(c.sourceToken, old);
      await http.runWithClient(c.close, () => client);
    });

    test('an error on an expired token recovers without a message', () async {
      final c = await open(old);
      var errors = 0;
      c.onPlaybackError = () => errors++;
      auth.clock = () => now.add(const Duration(hours: 1, seconds: 1));

      await http.runWithClient(() async {
        c.debugPlayerError(PlayerException(0, 'Response code: 401', 0));
        await until(() => c.sourceToken == renewed);
      }, () => client);

      expect(c.sourceToken, renewed);
      expect(errors, 0);
      await http.runWithClient(c.close, () => client);
    });

    test(
      'an expired token the server will not renew shows the error',
      () async {
        routes['POST /auth/refresh'] = () async => http.Response('', 401);
        final c = await open(old);
        var errors = 0;
        c.onPlaybackError = () => errors++;
        auth.clock = () => now.add(const Duration(hours: 1, seconds: 1));

        await http.runWithClient(() async {
          c.debugPlayerError(PlayerException(0, 'Response code: 401', 0));
          await until(() => errors > 0);
        }, () => client);

        expect(errors, 1);
        expect(c.sourceToken, old);
        await http.runWithClient(c.close, () => client);
      },
    );

    test('other errors with a valid token show the error', () async {
      final c = await open(old);
      var errors = 0;
      c
        ..onPlaybackError = (() => errors++)
        ..debugPlayerError(PlayerException(0, 'Connection lost', 0));

      expect(errors, 1);
      expect(requests, isNot(contains('POST /auth/refresh')));
      await http.runWithClient(c.close, () => client);
    });
  });
}
