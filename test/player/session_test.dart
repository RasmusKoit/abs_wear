import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

  group('closing', () {
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
}
