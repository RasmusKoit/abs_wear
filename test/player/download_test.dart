import 'dart:async';
import 'dart:io';

import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:abs_wear/player/darts/download_keep_alive.dart';
import 'package:abs_wear/player/darts/download_manager.dart';
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
}

const _channel = MethodChannel('download_keep_alive');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late List<String> calls;
  late bool onWifi;
  // Completes the native 'start' (the Wi-Fi wait); immediate by default.
  late Future<void> startDone;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('abs_download_test');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    calls = [];
    onWifi = false;
    startDone = Future.value();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          if (call.method != 'start') return null;
          await startDone;
          return onWifi;
        });
  });

  tearDown(() async {
    // The queue is global: nothing may run into the next test.
    await DownloadManager.instance.cancelAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    docs.deleteSync(recursive: true);
  });

  AudioPlayerController controllerWith(
    http.Client client, {
    String item = 'li_1',
  }) => AudioPlayerController(client: client)
    ..serverUrl = 'http://abs.test'
    ..libraryItemId = item
    ..bookTitle = 'Book $item'
    ..tracks = [
      BookTrack(
        index: 1,
        startOffset: 0,
        duration: 60,
        contentUrl: '/api/items/$item/file/111',
        filename: 'book.mp3',
        ino: '111',
        size: 1000,
      ),
    ];

  /// Answers each file with a body the test feeds; covers with 404.
  ({http.Client client, Map<String, StreamController<List<int>>> bodies})
  feedable() {
    final bodies = <String, StreamController<List<int>>>{};
    final client = MockClient.streaming((request, _) async {
      final path = request.url.path;
      if (path.endsWith('/cover')) {
        return http.StreamedResponse(const Stream.empty(), 404);
      }
      final body = bodies[path.split('/')[3]] = StreamController<List<int>>();
      return http.StreamedResponse(body.stream, 200, contentLength: 1000);
    });
    return (client: client, bodies: bodies);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  List<String> filesIn(Directory dir) => dir.existsSync()
      ? dir.listSync(recursive: true).map((e) => e.path).toList()
      : const [];

  test(
    'cancel stops a stalled download and removes the partial file',
    () async {
      final body = StreamController<List<int>>();
      final controller = controllerWith(
        MockClient.streaming((request, _) async {
          return http.StreamedResponse(body.stream, 200, contentLength: 1000);
        }),
      );

      final result = controller.downloadBook();
      // Some bytes arrive, then the connection stalls.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      body.add(List.filled(400, 1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.isDownloading, isTrue);
      expect(controller.downloadProgress.value, closeTo(0.4, 0.01));

      controller.cancelDownload();
      expect(
        await result.timeout(const Duration(seconds: 2)),
        DownloadResult.canceled,
      );
      expect(controller.isDownloading, isFalse);
      expect(controller.downloadProgress.value, isNull);
      expect(filesIn(docs).where((f) => f.endsWith('.part')), isEmpty);
      expect(calls, containsAllInOrder(['start', 'progress', 'stop']));
      await body.close();
    },
  );

  test('cancel while waiting for the response', () async {
    final controller = controllerWith(
      MockClient.streaming(
        (request, _) => Completer<http.StreamedResponse>().future,
      ),
    );

    final result = controller.downloadBook();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    controller.cancelDownload();
    expect(
      await result.timeout(const Duration(seconds: 2)),
      DownloadResult.canceled,
    );
    expect(calls.last, 'stop');
  });

  test('falls back to the default network when Wi-Fi fails', () async {
    onWifi = true;
    var requests = 0;
    final controller = controllerWith(
      MockClient.streaming((request, _) async {
        requests++;
        // Unreachable over Wi-Fi (the first try and its retry).
        if (requests <= 2) throw http.ClientException('No route to host');
        return http.StreamedResponse(const Stream.empty(), 404);
      }),
    );

    expect(await controller.downloadBook(), DownloadResult.failed);
    expect(requests, 3);
    expect(calls, ['start', 'useDefaultNetwork', 'stop']);
  });

  test('without Wi-Fi a failing request is not retried forever', () async {
    var requests = 0;
    final controller = controllerWith(
      MockClient.streaming((request, _) async {
        requests++;
        throw http.ClientException('Connection closed');
      }),
    );

    expect(await controller.downloadBook(), DownloadResult.failed);
    expect(requests, 2);
    expect(calls, ['start', 'stop']);
  });

  test('cancel during the Wi-Fi wait ends the download at once', () async {
    final wifi = Completer<void>();
    startDone = wifi.future;
    var requests = 0;
    final controller = controllerWith(
      MockClient.streaming((request, _) async {
        requests++;
        return http.StreamedResponse(const Stream.empty(), 404);
      }),
    );

    final result = controller.downloadBook();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    controller.cancelDownload();
    expect(
      await result.timeout(const Duration(seconds: 2)),
      DownloadResult.canceled,
    );
    expect(requests, 0);
    expect(calls, ['start', 'stop']);
    wifi.complete();
  });

  test('closing the player leaves its download running', () async {
    final feed = feedable();
    final controller = controllerWith(feed.client);

    final result = controller.downloadBook();
    await settle();
    await controller.close();
    expect(DownloadManager.instance.jobFor('li_1'), isNotNull);

    feed.bodies['li_1']!.add(List.filled(1000, 1));
    await feed.bodies['li_1']!.close();
    expect(
      await result.timeout(const Duration(seconds: 2)),
      DownloadResult.done,
    );
    expect(File('${docs.path}/li_1/001_111.mp3').lengthSync(), 1000);
    expect(calls.last, 'stop');
  });

  test('cancel ends the wait for the cover at once', () async {
    final coverAsked = Completer<void>();
    final controller = controllerWith(
      MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('/cover')) {
          coverAsked.complete();
          return Completer<http.StreamedResponse>().future;
        }
        return http.StreamedResponse(
          Stream.value(List.filled(1000, 1)),
          200,
          contentLength: 1000,
        );
      }),
    );

    final result = controller.downloadBook();
    await coverAsked.future.timeout(const Duration(seconds: 2));
    controller.cancelDownload();
    // The audio is all there, so the book counts as downloaded.
    expect(
      await result.timeout(const Duration(seconds: 2)),
      DownloadResult.done,
    );
    expect(DownloadManager.instance.jobs, isEmpty);
  });

  test('a second book waits for the first under one keep-alive', () async {
    final feed = feedable();
    final first = controllerWith(feed.client);
    final second = controllerWith(feed.client, item: 'li_2');

    final firstResult = first.downloadBook();
    final secondResult = second.downloadBook();
    await settle();
    expect(feed.bodies.keys, ['li_1']);
    expect(first.isDownloading, isTrue);
    expect(second.isDownloading, isTrue);
    // Queued: no progress yet.
    expect(second.downloadProgress.value, isNull);

    feed.bodies['li_1']!.add(List.filled(1000, 1));
    await feed.bodies['li_1']!.close();
    expect(await firstResult, DownloadResult.done);
    await settle();
    expect(feed.bodies.keys, ['li_1', 'li_2']);
    expect(second.downloadProgress.value, 0);

    feed.bodies['li_2']!.add(List.filled(1000, 1));
    await feed.bodies['li_2']!.close();
    expect(await secondResult, DownloadResult.done);
    await settle();
    expect(calls.where((c) => c == 'start'), hasLength(1));
    expect(calls, containsAllInOrder(['start', 'title', 'stop']));
    expect(calls.last, 'stop');
  });

  test('canceling a queued book leaves the running one alone', () async {
    final feed = feedable();
    final first = controllerWith(feed.client);
    final second = controllerWith(feed.client, item: 'li_2');

    final firstResult = first.downloadBook();
    final secondResult = second.downloadBook();
    await settle();
    second.cancelDownload();
    expect(await secondResult, DownloadResult.canceled);
    expect(second.isDownloading, isFalse);
    expect(first.isDownloading, isTrue);

    feed.bodies['li_1']!.add(List.filled(1000, 1));
    await feed.bodies['li_1']!.close();
    expect(await firstResult, DownloadResult.done);
    expect(feed.bodies.keys, ['li_1']);
  });

  test('downloading the same book again joins its download', () async {
    final feed = feedable();
    final controller = controllerWith(feed.client);
    final reopened = controllerWith(feed.client);

    final result = controller.downloadBook();
    final again = reopened.downloadBook();
    await settle();
    expect(DownloadManager.instance.jobs, hasLength(1));

    feed.bodies['li_1']!.add(List.filled(1000, 1));
    await feed.bodies['li_1']!.close();
    expect(await result, DownloadResult.done);
    expect(await again, DownloadResult.done);
  });

  test("the notification's cancel stops the whole queue", () async {
    final feed = feedable();
    final first = controllerWith(feed.client).downloadBook();
    final second = controllerWith(feed.client, item: 'li_2').downloadBook();
    await settle();

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          _channel.codec.encodeMethodCall(const MethodCall('cancel')),
          (_) {},
        );
    expect(await first, DownloadResult.canceled);
    expect(await second, DownloadResult.canceled);
    expect(DownloadManager.instance.jobs, isEmpty);
    expect(feed.bodies.keys, ['li_1']);
    await settle();
    expect(calls.last, 'stop');
  });

  test("an old download ending doesn't stop a newer one", () async {
    final old = DownloadKeepAlive.start(
      title: 'A',
      cancelLabel: 'Cancel',
      channelName: 'Downloads',
      onCancel: () {},
    );
    var canceled = false;
    final current = DownloadKeepAlive.start(
      title: 'B',
      cancelLabel: 'Cancel',
      channelName: 'Downloads',
      onCancel: () => canceled = true,
    );
    await old.onWifi;
    await current.onWifi;

    await old.stop();
    expect(calls, ['start', 'start']);
    // The notification's cancel still reaches the newer download.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          _channel.codec.encodeMethodCall(const MethodCall('cancel')),
          (_) {},
        );
    expect(canceled, isTrue);

    await current.stop();
    expect(calls, ['start', 'start', 'stop']);
  });
}
