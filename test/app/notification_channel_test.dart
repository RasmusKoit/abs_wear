import 'package:abs_wear/app/notification_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('notification_channel');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('nameAudioChannel renames the channel audio_service uses', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    await nameAudioChannel('Audiowiedergabe');
    expect(calls.single.method, 'nameAudio');
    expect(calls.single.arguments, {
      'id': 'dev.koit.abs_wear.channel.audio',
      'name': 'Audiowiedergabe',
    });
  });

  test('nameAudioChannel never throws', () async {
    // No handler: MissingPluginException.
    await nameAudioChannel('Audio playback');
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'boom'),
    );
    await nameAudioChannel('Audio playback');
  });
}
