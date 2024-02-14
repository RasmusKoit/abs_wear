import 'package:abs_wear/app/app.dart';
import 'package:abs_wear/bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'dev.koit.abs_wear.channel.audio',
    androidNotificationChannelName: 'Audio playback',
    androidNotificationOngoing: true,
  );
  await bootstrap(() => const App());
}
