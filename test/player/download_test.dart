import 'dart:async';
import 'dart:io';

import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:abs_wear/player/darts/download_keep_alive.dart';
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

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    docs.deleteSync(recursive: true);
  });

  AudioPlayerController controllerWith(http.Client client) =>
      AudioPlayerController(client: client)
        ..serverUrl = 'http://abs.test'
        ..libraryItemId = 'li_1'
        ..tracks = const [
          BookTrack(
            index: 1,
            startOffset: 0,
            duration: 60,
            contentUrl: '/api/items/li_1/file/111',
            filename: 'book.mp3',
            ino: '111',
            size: 1000,
          ),
        ];

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

  test('closing the player cancels its download', () async {
    final body = StreamController<List<int>>();
    final controller = controllerWith(
      MockClient.streaming((request, _) async {
        return http.StreamedResponse(body.stream, 200, contentLength: 1000);
      }),
    );

    final result = controller.downloadBook();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    unawaited(controller.close());
    expect(
      await result.timeout(const Duration(seconds: 2)),
      DownloadResult.canceled,
    );
    expect(calls.last, 'stop');
    await body.close();
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
