import 'package:audiobookshelfwear/app/app.dart';
import 'package:audiobookshelfwear/bootstrap.dart';
import 'package:just_audio_background/just_audio_background.dart';

Future<void> main() async {
  await JustAudioBackground.init(
    androidNotificationChannelId: 'dev.koit.audiobookshelfwear.channel.audio',
    androidNotificationChannelName: 'Audio playback',
    androidNotificationOngoing: true,
  );
  await bootstrap(() => const App());
}
