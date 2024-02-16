// ignore_for_file: avoid_dynamic_calls

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/components/scrolling_text.dart';
import 'package:abs_wear/player/components/time_left_widget.dart';
import 'package:archive/archive.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rotary_scrollbar/rotary_scrollbar.dart';
import 'package:volume_controller/volume_controller.dart';

class PlayerView extends StatefulWidget {
  const PlayerView({
    required this.token,
    required this.serverUrl,
    required this.libraryItemId,
    required this.user,
    super.key,
  });
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
  final PageController _pageController = PageController();
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
  double _getVolume = 0;
  String _downloadUrl = '';
  bool isMediaOffline = false;

  @override
  void initState() {
    super.initState();
    try {
      _init();
    } catch (e) {
      if (kDebugMode) {
        print('Error initializing player: $e');
      }
      // pop the current view
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    _syncTimer?.cancel();
    if (!_isBuffering) {
      _syncOpenSession(
        startingPositionTime,
        _player.position.inSeconds.toDouble(),
        close: true,
      );
    }
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
      try {
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
      } catch (e) {
        if (kDebugMode) {
          print('Error syncing session: $e');
        }
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _init() async {
    if (mounted) {
      await setupPlayer();
    }
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

    if (!_isBuffering) {
      _syncTimer = Timer.periodic(
        const Duration(minutes: 1),
        (timer) {
          if (mounted) {
            _syncOpenSession(
              startingPositionTime,
              _player.position.inSeconds.toDouble(),
            );
          }
        },
      );
    }
  }

  Future<void> setupPlayer() async {
    try {
      final libraryItemId = widget.libraryItemId;

      // Check if the audio file is locally available
      final localFilePath = await _getLocalFilePath(libraryItemId, true);

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
      if (mounted) {
        setState(() {
          bookTitle = playData['mediaMetadata']['title'] as String;
          chapterName = getChapterName(
              (playData['currentTime'] as num).round(), chapters);
        });
      }

      // find the first item where fileType is audio

      final inoInt = playData['libraryItem']['libraryFiles'].firstWhere(
        (item) => item['fileType'] == 'audio',
      )['ino'] as String;

      // final inoInt =
      //     playData['libraryItem']['libraryFiles'][0]['ino'] as String;
      final audioUrl =
          '${widget.serverUrl}/api/items/$libraryItemId/file/$inoInt';
      _downloadUrl =
          '${widget.serverUrl}/api/items/$libraryItemId/download?token=${widget.token}';
      if (localFilePath.isNotEmpty && mounted) {
        isMediaOffline = true;
        if (kDebugMode) {
          print('Local Audio file found!');
        }
        try {
          await _player.setAudioSource(
            AudioSource.uri(
              Uri.file(localFilePath),
              tag: MediaItem(
                id: libraryItemId,
                album: bookTitle,
                title: chapterName,
              ),
            ),
            initialPosition: Duration(seconds: startingPositionTime.round()),
          );
        } on PlayerInterruptedException catch (e) {
          if (kDebugMode) {
            print(
              'PlayerInterruptedException: Error setting audiotrack up for player: $e ${e.runtimeType}',
            );
          }
        } on PlatformException catch (e) {
          if (kDebugMode) {
            print(
                'PlatformException: Error setting audiotrack up for player: $e ${e.runtimeType}');
          }
        } catch (e) {
          if (kDebugMode) {
            print(
                'Error setting audiotrack up for player: $e ${e.runtimeType}');
          }
        }
      } else {
        if (kDebugMode) {
          print('Local Audio file not found!');
        }
        try {
          await _player.setAudioSource(
            AudioSource.uri(
              Uri.parse(audioUrl),
              headers: <String, String>{
                'Authorization': 'Bearer ${widget.token}',
              },
              tag: MediaItem(
                id: libraryItemId,
                album: bookTitle,
                title: chapterName,
              ),
            ),
            initialPosition: Duration(
              seconds: (playData['currentTime'] as num).round(),
            ),
          );
        } on PlayerInterruptedException catch (e) {
          if (kDebugMode) {
            print(
              'PlayerInterruptedException: Error setting audiotrack up for player: $e ${e.runtimeType}',
            );
          }
        } on PlatformException catch (e) {
          if (kDebugMode) {
            print(
                'PlatformException: Error setting audiotrack up for player: $e ${e.runtimeType}');
          }
        } catch (e) {
          if (kDebugMode) {
            print(
                'Error setting audiotrack up for player: $e ${e.runtimeType}');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error setting up player: $e');
      }
    }
  }

  Future<void> _downloadFile() async {
    final httpClient = http.Client();

    final request = http.Request('GET', Uri.parse(_downloadUrl));
    final response = await httpClient.send(request);

    if (response.statusCode == 200) {
      // Save the file to the device
      // Downloaded file is a .zip file

      final folderPath = await _getLocalFilePath(widget.libraryItemId, false);
      final zipFilePath = '$folderPath/${widget.libraryItemId}.zip';

      // Check if FolderPath exists, if not create it
      final dir = Directory(folderPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      } else {
        // Delete the existing files
        for (final file in dir.listSync()) {
          file.deleteSync();
        }
      }

      // Download the zip file by streaming
      final zipFile = File(zipFilePath);
      await response.stream.pipe(zipFile.openWrite());

      // Unzip the file
      if (_isZipFile(zipFile)) {
        final bytes = zipFile.readAsBytesSync();
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final file in archive) {
          final filename = '$folderPath/${file.name}';
          if (file.isFile) {
            final data = file.content as List<int>;
            File(filename)
              ..createSync(recursive: true)
              ..writeAsBytesSync(data);
          }
        }
        // Delete the zip file
        zipFile.deleteSync();
      }
      setState(() {
        isMediaOffline = true;
        _isBuffering = true;
        _isPlaying = false;
      });
      await _player.stop();
      // sync current progress
      await _syncOpenSession(
        startingPositionTime,
        _player.position.inSeconds.toDouble(),
      );
      await _init();
    }
  }

  Future<void> _deleteMedia() async {
    final folderPath = await _getLocalFilePath(widget.libraryItemId, false);
    final dir = Directory(folderPath);
    if (dir.existsSync()) {
      setState(() {
        isMediaOffline = false;
        _isBuffering = true;
        _isPlaying = false;
      });
      await _player.stop();
      await _syncOpenSession(
        startingPositionTime,
        _player.position.inSeconds.toDouble(),
        close: true,
      );
      dir.deleteSync(recursive: true);
    }
    await _init();
  }

  bool _isZipFile(File file) {
    // Check if the file has a .zip extension (you may need to improve this check based on your requirements)
    return file.path.toLowerCase().endsWith('.zip');
  }

  Future<String> _getLocalFilePath(
    String libraryItemId,
    bool getAudioFile,
  ) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final folderPath = '${appDocDir.path}/$libraryItemId';
    if (!getAudioFile) {
      return folderPath;
    }
    // Get a list of files in the specified folder
    final dir = Directory(folderPath);
    if (!dir.existsSync()) {
      return '';
    }
    final files = await dir.list().toList();
    // Search for audio files with known extensions
    final audioExtensions = [
      '.mp3',
      '.m4a',
      '.m4b',
      '.aac',
      '.flac',
    ]; // Add more if needed

    for (final file in files) {
      // check if file.path ends with any of the audio extensions
      if (audioExtensions.any((ext) => file.path.endsWith(ext))) {
        return file.path;
      }
    }

    // If no audio file is found, return an empty string
    return '';
  }

  Stream<Duration> get positionStream {
    return Stream.periodic(const Duration(seconds: 1), (_) => _player.position);
  }

  String durationPlayed(int inSeconds) {
    final hours = inSeconds ~/ 3600;
    final minutes = (inSeconds % 3600) ~/ 60;
    final seconds = inSeconds % 60;
    // ignore: lines_longer_than_80_chars
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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
        // ignore: lines_longer_than_80_chars
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
        await _player.seek(
          Duration(
            seconds: (previousChapter['start'] as num).round(),
          ),
        );
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
    final theme = Theme.of(context);

    return RotaryScrollWrapper(
      rotaryScrollbar: RotaryScrollbar(
        width: 2,
        hasHapticFeedback: false,
        autoHide: false,
        controller: _pageController,
      ),
      child: Scaffold(
          body: Row(
        children: <Widget>[
          Expanded(
            child: PageView(
              scrollDirection: Axis.vertical,
              controller: _pageController,
              children: [
                _buildPlayerPage(theme),
                _buildPlayerControlsPage(context, theme),
              ],
            ),
          ),
        ],
      )),
    );
  }

  Widget _buildPlayerControlsPage(BuildContext context, ThemeData theme) {
    final l10n = context.l10n;
    return Stack(
      children: <Widget>[
        // Existing widgets
        SizedBox.expand(
          child: Scaffold(
            appBar: AppBar(
              centerTitle: true,
              automaticallyImplyLeading: false,
              title: Text(
                l10n.controls,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_rounded),
                          onPressed: () async {
                            _getVolume = await VolumeController().getVolume();
                            VolumeController().setVolume(
                              _getVolume - 0.1,
                              showSystemUI: false,
                            );
                          },
                        ),
                        Icon(
                          _getVolume > 0.5
                              ? Icons.volume_up_rounded
                              : Icons.volume_down_rounded,
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_rounded),
                          onPressed: () async {
                            _getVolume = await VolumeController().getVolume();
                            VolumeController().setVolume(
                              _getVolume + 0.1,
                              showSystemUI: false,
                            );
                          },
                        ),
                      ],
                    ),
                    Text(
                      l10n.offlineListening,
                      style: theme.textTheme.labelMedium,
                    ),
                    _buildOfflineMediaAction(theme),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOfflineMediaAction(ThemeData theme) {
    if (isMediaOffline && !_isBuffering) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: Icon(
              isMediaOffline
                  ? Icons.download_done_rounded
                  : Icons.download_rounded,
              color: isMediaOffline
                  ? theme.colorScheme.primary
                  : theme.colorScheme.secondary,
            ),
            onPressed: () async {
              if (!isMediaOffline && !_isBuffering) {
                await _downloadFile();
              }
            },
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_forever_rounded,
              color: Colors.red,
            ),
            onPressed: () async {
              await _deleteMedia();
              setState(() {
                isMediaOffline = false;
                _isBuffering = true;
              });
              await setupPlayer();
            },
          ),
        ],
      );
    } else {
      return IconButton(
        icon: Icon(
          isMediaOffline ? Icons.download_done_rounded : Icons.download_rounded,
          color: isMediaOffline
              ? theme.colorScheme.primary
              : theme.colorScheme.secondary,
        ),
        onPressed: () async {
          if (!isMediaOffline && !_isBuffering) {
            await _downloadFile();
          }
        },
      );
    }
  }

  Widget _buildPlayerPage(ThemeData theme) {
    return Stack(
      children: <Widget>[
        // Existing widgets
        SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 8),
              _buildScrollingText(
                theme.textTheme.labelMedium!,
                bookTitle,
                30,
                2.5,
              ),
              _buildScrollingText(
                theme.textTheme.labelSmall!,
                chapterName,
                22,
                0,
              ),
              _buildPlaybackControls(),
              _buildSeekButtons(),
              _buildTimeLeftWidget(theme.textTheme.labelSmall!),
            ],
          ),
        ),
        // DotsIndicator on the right
      ],
    );
  }

  Widget _buildScrollingText(
    TextStyle textStyle,
    String text,
    double horizontalPadding,
    double verticalPadding,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      child: ScrollingText(
        text: text,
        style: textStyle,
      ),
    );
  }

  Widget _buildPlaybackControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          onPressed: seekToPrevious,
        ),
        _buildPlayPauseButton(),
        IconButton(
          icon: const Icon(Icons.skip_next),
          onPressed: seekToNext,
        ),
      ],
    );
  }

  Widget _buildPlayPauseButton() {
    return _isBuffering
        ? const SizedBox(
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
        : IconButton(
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
          );
  }

  Widget _buildSeekButtons() {
    return Row(
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
    );
  }

  Widget _buildTimeLeftWidget(TextStyle textStyle) {
    return ValueListenableBuilder<String>(
      valueListenable: _timeLeftNotifier,
      builder: (context, value, child) {
        return TimeLeftWidget(
          timeLeft: value,
          style: textStyle,
        );
      },
    );
  }
}
