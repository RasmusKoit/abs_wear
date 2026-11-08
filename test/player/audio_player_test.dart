import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('chapterIndexAt', () {
    late AudioPlayerController controller;

    setUp(() {
      controller = AudioPlayerController()
        ..chapters = const [
          BookChapter(start: 0, end: 60, title: 'One'),
          BookChapter(start: 60.0004, end: 120, title: 'Two'),
          BookChapter(start: 125, end: 180, title: 'Three'),
        ];
    });

    test('returns -1 before the first chapter', () {
      controller.chapters = const [BookChapter(start: 5, end: 10, title: 'A')];
      expect(controller.chapterIndexAt(1), -1);
    });

    test('a millisecond-rounded seek to a chapter start lands in it', () {
      // Seeking to 60.0004 s is sent as 60000 ms.
      expect(controller.chapterIndexAt(60), 1);
    });

    test('gaps between chapters belong to the previous chapter', () {
      expect(controller.chapterIndexAt(122), 1);
      expect(controller.chapterIndexAt(125), 2);
    });
  });

  test('formatDuration pads hours, minutes and seconds', () {
    expect(
      formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '01:02:03',
    );
  });
}
