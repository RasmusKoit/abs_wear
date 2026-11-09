import 'package:flutter/services.dart';

const _channel = MethodChannel('notification_channel');

/// The media notification's channel, which audio_service creates.
const audioChannelId = 'dev.koit.abs_wear.channel.audio';

/// Names the media notification's channel (handled by MainActivity).
/// audio_service sets the name only when it first creates the channel, so
/// an existing install would keep its first language for good. Fails
/// silently: the channel then just keeps its old name.
Future<void> nameAudioChannel(String name) async {
  try {
    await _channel.invokeMethod<void>('nameAudio', {
      'id': audioChannelId,
      'name': name,
    });
  } on Exception {
    // No platform side (tests, or an engine started without the activity).
  }
}
