import 'dart:async';
import 'dart:convert';

import 'package:audiobookshelfwear/l10n/l10n.dart';
import 'package:audiobookshelfwear/player/components/scrolling_text.dart';
import 'package:audiobookshelfwear/player/components/time_left_widget.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

class PlayerView extends StatefulWidget {
  const PlayerView(
      {super.key,
      required this.token,
      required this.serverUrl,
      required this.libraryItemId,
      required this.user});
  final String token;
  final String serverUrl;
  final String libraryItemId;
  final String user;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  StreamSubscription<Duration>? _positionSubscription;
  final ValueNotifier<String> _timeLeftNotifier = ValueNotifier<String>('');
  final _player = AudioPlayer();
  bool _isPlaying = false;
  bool _isBuffering = true;
  List<dynamic> chapters = [];
  String bookTitle = '';
  String chapterName = '';
  String sessionId = '';
  double startingPositionTime = 0;
  double duration = 0;
  double timeListened = 0;
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    super.dispose();
    _syncTimer?.cancel();
    _syncOpenSession(
      startingPositionTime,
      _player.position.inSeconds.toDouble(),
      close: true,
    );
    _player.stop();
    _timeLeftNotifier.dispose();
    _positionSubscription?.cancel();
    _player.dispose();
  }

  Future<void> _syncOpenSession(
    double lastCurrentTime,
    double currentTime, {
    bool close = false,
  }) async {
    if (sessionId.isNotEmpty) {
      final sessionUri =
          '${widget.serverUrl}/api/session/$sessionId/${close ? 'close' : 'sync'}';
      timeListened = currentTime - lastCurrentTime;
      final sessionBody = <String, double>{
        'currentTime': _player.position.inSeconds.toDouble(),
        'timeListened': timeListened,
        'duration': duration,
      };
      // If close is true, then we are closing the session
      final closeResponse = await http.post(
        Uri.parse(sessionUri),
        headers: <String, String>{
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(sessionBody),
      );
      if (closeResponse.statusCode != 200) {
        return;
      }
      // update the starting position time
      startingPositionTime = currentTime;
    }
  }

  Future<void> _init() async {
    await setupPlayer();
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready) {
        setState(() {
          _isBuffering = false;
        });
      } else if (state == ProcessingState.buffering) {
        setState(() {
          _isBuffering = true;
        });
      }
    });

    _positionSubscription = _player.positionStream.listen((event) {
      updateChapterNameAndDuration();
    });

    _syncTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (!_isBuffering) {
        _syncOpenSession(
          startingPositionTime,
          _player.position.inSeconds.toDouble(),
        );
      }
    });
  }

  Future<void> setupPlayer() async {
    final libraryItemId = widget.libraryItemId;

    final playUri = '${widget.serverUrl}/api/items/$libraryItemId/play';
    final deviceInfoPlugin = DeviceInfoPlugin();
    final buildInfo = await deviceInfoPlugin.androidInfo;
    final playResponseBody = '''
{
  "deviceInfo": {
    "clientName": "Wear OS",
    "clientVersion": "${buildInfo.version.release}",
    "deviceName": "${buildInfo.device}",
    "deviceType": "wearable",
    "sdkVersion": ${buildInfo.version.sdkInt},
    "model": "${buildInfo.model}",
    "manufacturer": "${buildInfo.manufacturer == 'unknown' ? 'Google' : buildInfo.manufacturer}"
  },
  "mediaPlayer": "JustAudio",
  "forceDirectPlay": true
}
''';

    final playResponse = await http.post(
      Uri.parse(playUri),
      headers: <String, String>{
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode(jsonDecode(playResponseBody)),
    );

    if (playResponse.statusCode != 200) {
      return;
    }

    final playData = jsonDecode(playResponse.body) as Map<String, dynamic>;
    sessionId = playData['id'] as String;
    chapters = playData['chapters'] as List<dynamic>;
    startingPositionTime = (playData['currentTime'] as num).toDouble();
    duration = (playData['duration'] as num).toDouble();

    setState(() {
      bookTitle = playData['mediaMetadata']['title'] as String;
      chapterName =
          getChapterName((playData['currentTime'] as num).round(), chapters);
    });
    final inoInt = playData['libraryItem']['libraryFiles'][0]['ino'] as String;
    final audioUrl =
        '${widget.serverUrl}/api/items/$libraryItemId/file/$inoInt';

    await _player.setUrl(
      audioUrl,
      headers: <String, String>{
        'Authorization': 'Bearer ${widget.token}',
      },
      initialPosition: Duration(
        seconds: (playData['currentTime'] as num).round(),
      ),
    );
  }

  Stream<Duration> get positionStream {
    return Stream.periodic(const Duration(seconds: 1), (_) => _player.position);
  }

  String durationPlayed(int inSeconds) {
    final hours = inSeconds ~/ 3600;
    final minutes = (inSeconds % 3600) ~/ 60;
    final seconds = inSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.floor().toString().padLeft(2, '0')}';
  }

  String getTimeLeft(int inSeconds, List<dynamic> chapters) {
    if (chapters.isEmpty) {
      return durationPlayed(inSeconds);
    }
    for (final chapter in chapters) {
      final start = chapter['start'] as num;
      final end = chapter['end'] as num;
      if (inSeconds >= start && inSeconds <= end) {
        final remainingSeconds = end - inSeconds;
        final hours = remainingSeconds ~/ 3600;
        final minutes = (remainingSeconds % 3600) ~/ 60;
        final seconds = remainingSeconds % 60;
        return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.floor().toString().padLeft(2, '0')}';
      }
    }
    return 'Unknown';
  }

  Future<void> seekToPrevious() async {
    if (_player.hasPrevious) {
      await _player.seekToPrevious();
    } else {
      // Implement logic to go to previous chapter
      final currentChapter =
          getChapterName(_player.position.inSeconds, chapters);
      final currentChapterIndex =
          chapters.indexWhere((chapter) => chapter['title'] == currentChapter);
      if (currentChapterIndex > 0) {
        final previousChapter = chapters[currentChapterIndex - 1];
        await _player.seek(Duration(
          seconds: (previousChapter['start'] as num).round(),
        ));
        setState(() {
          chapterName = previousChapter['title'] as String;
        });
      }
    }
  }

  Future<void> seekToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext();
    } else {
      // Implement logic to go to next chapter
      final currentChapter =
          getChapterName(_player.position.inSeconds, chapters);
      final currentChapterIndex =
          chapters.indexWhere((chapter) => chapter['title'] == currentChapter);
      if (currentChapterIndex < chapters.length - 1) {
        final nextChapter = chapters[currentChapterIndex + 1];
        await _player
            .seek(Duration(seconds: (nextChapter['start'] as num).round()));
        setState(() {
          chapterName = nextChapter['title'] as String;
        });
      }
    }
  }

  Future<void> seekTo(int position) async {
    await _player.seek(Duration(seconds: position));
  }

  String getChapterName(int inSeconds, List<dynamic> chapters) {
    for (final chapter in chapters) {
      final start = chapter['start'] as num;
      final end = chapter['end'] as num;
      if (inSeconds >= start && inSeconds <= end) {
        return chapter['title'] as String;
      }
    }
    return 'None found';
  }

  void updateChapterNameAndDuration() {
    final newTimeLeft = getTimeLeft(_player.position.inSeconds, chapters);
    if (newTimeLeft != _timeLeftNotifier.value) {
      _timeLeftNotifier.value = newTimeLeft;
      if (_timeLeftNotifier.value == '00:00:00') {
        setState(() {
          // Update chapterName
          chapterName =
              getChapterName(_player.position.inSeconds + 5, chapters);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Scaffold(
      body: SizedBox.expand(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 25),
                child: ScrollingText(
                  text: bookTitle,
                  style: theme.textTheme.labelMedium!,
                )),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 25),
              child: ScrollingText(
                text: chapterName,
                style: theme.textTheme.labelSmall!,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: seekToPrevious,
                ),
                if (_isBuffering)
                  const SizedBox(
                    height: 48,
                    width: 48,
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    ),
                  )
                else
                  IconButton(
                    icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: () {
                      setState(() {
                        if (_isPlaying) {
                          _player.pause();
                        } else {
                          _player.play();
                        }
                        _isPlaying = !_isPlaying;
                      });
                    },
                  ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: seekToNext,
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.replay_10_rounded),
                  onPressed: () => seekTo(-10 + _player.position.inSeconds),
                ),
                IconButton(
                  icon: const Icon(Icons.forward_10_rounded),
                  onPressed: () => seekTo(10 + _player.position.inSeconds),
                ),
              ],
            ),
            ValueListenableBuilder<String>(
              valueListenable: _timeLeftNotifier,
              builder: (context, value, child) {
                return TimeLeftWidget(
                  timeLeft: value,
                  style: theme.textTheme.labelSmall!,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
