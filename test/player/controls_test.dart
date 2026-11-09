import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// Seeking, chapter skips and the sleep timer, on a player with no audio
/// loaded (positions then come from the controller, not the engine).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const chapters = [
    BookChapter(start: 0, end: 100, title: 'One'),
    BookChapter(start: 100, end: 250, title: 'Two'),
    // A gap from 250 to 260 belongs to Two.
    BookChapter(start: 260, end: 600, title: 'Three'),
  ];

  AudioPlayerController controller() => AudioPlayerController()
    ..duration = 600
    ..chapters = chapters;

  group('seekRelative', () {
    test('moves from the current position', () async {
      final c = controller();
      await c.seekToBookTime(200);

      await c.seekRelative(30);
      expect(c.bookPosition, 230);
      await c.seekRelative(-10);
      expect(c.bookPosition, 220);
    });

    test('stops at the start of the book', () async {
      final c = controller();
      await c.seekToBookTime(10);

      await c.seekRelative(-30);

      expect(c.bookPosition, 0);
    });

    test('stops at the end of the book', () async {
      final c = controller();
      await c.seekToBookTime(590);

      await c.seekRelative(30);

      expect(c.bookPosition, 600);
    });

    test('skips add up', () async {
      final c = controller();
      for (var i = 0; i < 5; i++) {
        await c.seekRelative(30);
      }
      expect(c.bookPosition, 150);
      expect(c.chapterName, 'Two');
    });
  });

  group('seekToNextChapter', () {
    test('goes to the start of the next chapter', () async {
      final c = controller();
      await c.seekToBookTime(50);

      await c.seekToNextChapter();
      expect(c.bookPosition, 100);
      await c.seekToNextChapter();
      expect(c.bookPosition, 260);
      expect(c.chapterName, 'Three');
    });

    test('from a gap goes to the chapter after it', () async {
      final c = controller();
      await c.seekToBookTime(255);

      await c.seekToNextChapter();

      expect(c.bookPosition, 260);
    });

    test('stays put in the last chapter', () async {
      final c = controller();
      await c.seekToBookTime(400);

      await c.seekToNextChapter();

      expect(c.bookPosition, 400);
    });

    test('goes to the first chapter from before it', () async {
      final c = controller()
        ..chapters = const [BookChapter(start: 30, end: 600, title: 'A')];
      await c.seekToBookTime(10);

      await c.seekToNextChapter();

      expect(c.bookPosition, 30);
    });

    test('does nothing without chapters', () async {
      final c = controller()..chapters = [];
      await c.seekToBookTime(10);

      await c.seekToNextChapter();

      expect(c.bookPosition, 10);
    });
  });

  group('seekToPreviousChapter', () {
    test('restarts the chapter after its first 3 seconds', () async {
      final c = controller();
      await c.seekToBookTime(150);

      await c.seekToPreviousChapter();

      expect(c.bookPosition, 100);
    });

    test('goes to the previous chapter within its first 3 seconds', () async {
      final c = controller();
      await c.seekToBookTime(102);

      await c.seekToPreviousChapter();

      expect(c.bookPosition, 0);
    });

    test('a double tap goes back two chapter starts', () async {
      final c = controller();
      await c.seekToBookTime(300);

      await c.seekToPreviousChapter();
      expect(c.bookPosition, 260);
      await c.seekToPreviousChapter();
      expect(c.bookPosition, 100);
    });

    test('restarts the first chapter', () async {
      final c = controller();
      await c.seekToBookTime(1);

      await c.seekToPreviousChapter();

      expect(c.bookPosition, 0);
    });

    test('goes to the start before the first chapter', () async {
      final c = controller()
        ..chapters = const [BookChapter(start: 30, end: 600, title: 'A')];
      await c.seekToBookTime(10);

      await c.seekToPreviousChapter();

      expect(c.bookPosition, 0);
    });

    test('goes to the start without chapters', () async {
      final c = controller()..chapters = [];
      await c.seekToBookTime(400);

      await c.seekToPreviousChapter();

      expect(c.bookPosition, 0);
    });
  });

  group('timeLeft', () {
    test('counts to the end of the chapter', () async {
      final c = controller();
      await c.seekToBookTime(150);

      expect(c.timeLeft, const Duration(seconds: 100));
    });

    test('is zero in the gap after a chapter', () async {
      final c = controller();
      await c.seekToBookTime(255);

      expect(c.timeLeft, Duration.zero);
    });

    test('counts to the end of the book without chapters', () async {
      final c = controller()..chapters = [];
      await c.seekToBookTime(150);

      expect(c.timeLeft, const Duration(seconds: 450));
    });
  });

  group('sleep timer', () {
    test('each tap picks the next length, then turns it off', () {
      final c = controller();
      final shown = <Duration?>[];
      c.sleepRemaining.addListener(() => shown.add(c.sleepRemaining.value));

      for (var i = 0; i <= AudioPlayerController.sleepOptions.length; i++) {
        c.cycleSleepTimer();
      }

      expect(shown, [
        const Duration(minutes: 15),
        const Duration(minutes: 30),
        const Duration(minutes: 45),
        const Duration(minutes: 60),
        null,
      ]);
      // And starts over.
      c.cycleSleepTimer();
      expect(c.sleepRemaining.value, const Duration(minutes: 15));
    });

    test('picking an option directly starts it at full length', () {
      final c = controller()..setSleepTimer(3);
      expect(c.sleepRemaining.value, const Duration(minutes: 60));

      c.setSleepTimer(null);
      expect(c.sleepRemaining.value, isNull);

      // The next tap starts from the first option again.
      c.cycleSleepTimer();
      expect(c.sleepRemaining.value, const Duration(minutes: 15));
    });

    testWidgets("doesn't count down or tick while paused", (tester) async {
      // Fake time: a running tick would show here, and a live periodic
      // timer would fail the test at teardown.
      final c = controller()..setSleepTimer(0);

      await tester.pump(const Duration(minutes: 20));

      expect(c.sleepRemaining.value, const Duration(minutes: 15));
    });

    test('is ignored once the player closed', () async {
      final c = controller();
      await c.close();

      // sleepRemaining is disposed: changing it would throw.
      c
        ..cycleSleepTimer()
        ..setSleepTimer(null);
    });
  });
}
