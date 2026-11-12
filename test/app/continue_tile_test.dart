import 'dart:async';

import 'package:abs_wear/app/continue_tile.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = ContinueTile.channel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('take returns the book a tile tap asked for', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'take');
      return {'id': 'pod_1', 'episodeId': 'ep_1'};
    });
    final open = await ContinueTile.take();
    expect(open?.id, 'pod_1');
    expect(open?.episodeId, 'ep_1');
  });

  test('take without an episode', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'id': 'li_1', 'episodeId': null},
    );
    final open = await ContinueTile.take();
    expect(open?.id, 'li_1');
    expect(open?.episodeId, isNull);
  });

  test('take is null when nothing is pending or the platform fails', () async {
    expect(await ContinueTile.take(), isNull);
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await ContinueTile.take(), isNull);
    messenger.setMockMethodCallHandler(channel, (_) async => {'id': ''});
    expect(await ContinueTile.take(), isNull);
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'boom'),
    );
    expect(await ContinueTile.take(), isNull);
  });

  test('refresh asks the platform and never throws', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    await ContinueTile.refresh();
    expect(calls, ['refresh']);
    messenger.setMockMethodCallHandler(channel, null);
    await ContinueTile.refresh();
  });

  test('opens fires when the platform reports a tap', () async {
    final fired = Completer<void>();
    final sub = ContinueTile.opens.listen((_) => fired.complete());
    await simulatePlatformCall(channel.name, 'open');
    await fired.future.timeout(const Duration(seconds: 1));
    await sub.cancel();
  });
}
