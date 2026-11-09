import 'package:abs_wear/app/app.dart';
import 'package:abs_wear/app/notification_channel.dart';
import 'package:abs_wear/bootstrap.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final channelName = deviceL10n().audioPlaybackChannel;
  await JustAudioBackground.init(
    androidNotificationChannelId: audioChannelId,
    androidNotificationChannelName: channelName,
    androidNotificationOngoing: true,
  );
  // Renames a channel created before, e.g. in another language.
  await nameAudioChannel(channelName);
  await bootstrap(() => const App());
}
