// audio_player.dart
// contains the audio player and the audio player controller

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';

class AudioPlayerController extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  List<dynamic> chapters = [];
  String sessionId = '';
  double startingPositionTime = 0;
  double duration = 0;
  String bookTitle = '';
  String chapterName = '';
  String libraryItemId = '';
  String serverUrl = '';
  String inoInt = '';
  String onlineAudioUrl = '';
  String downloadUrl = '';
  String localDirPath = '';
  String token = '';
  bool isPlaying = false;
  bool isDownloading = false;

  Future<AudioPlayer?> setupPlayer(
    String libItemId,
    String srvUrl,
    String token,
  ) async {
    //
    libraryItemId = libItemId;
    serverUrl = srvUrl;
    this.token = token;
    final playUri = Uri.parse('$srvUrl/api/items/$libItemId/play');
    final playResponseBody = await getDeviceInfoBody();
    final playResponse = await http.post(
      playUri,
      headers: <String, String>{
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: playResponseBody,
    );

    if (playResponse.statusCode != 200) {
      return null;
    }
    final playResponseJson =
        jsonDecode(playResponse.body) as Map<String, dynamic>;
    await setPlaydataValues(playResponseJson);
    try {
      final playerAudioSource = await getAudioSourceUri();
      final playerHeaders = await getAudioSourceHeaders();
      await player.setAudioSource(
        AudioSource.uri(
          playerAudioSource,
          headers: playerHeaders,
          tag: MediaItem(
            id: libraryItemId,
            title: chapterName,
            album: bookTitle,
          ),
        ),
        initialPosition: Duration(seconds: startingPositionTime.round()),
        preload: false,
      );
      return player;
    } on PlayerInterruptedException catch (e) {
      if (kDebugMode) {
        print(
          '$e: Error setting audiotrack up for player: ${e.runtimeType}',
        );
      }
    } on PlatformException catch (e) {
      if (kDebugMode) {
        print(
          '$e: Error setting audiotrack up for player: ${e.runtimeType}',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print(
          '$e: Error setting audiotrack up for player:  ${e.runtimeType}',
        );
      }
    }
    return null;
  }

  Future<String> getDeviceInfoBody() async {
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
    return jsonEncode(jsonDecode(playResponseBody));
  }

  Future<void> setPlaydataValues(Map<String, dynamic> resJson) async {
    // Set values
    sessionId = resJson['id'] as String;
    chapters = resJson['chapters'] as List<dynamic>;
    startingPositionTime = (resJson['currentTime'] as num).toDouble();
    duration = (resJson['duration'] as num).toDouble();
    // ignore: avoid_dynamic_calls
    bookTitle = resJson['mediaMetadata']['title'] as String;
    chapterName = getChapterName(startingPositionTime);
    inoInt = getInoInt(resJson);
    onlineAudioUrl = '$serverUrl/api/items/$libraryItemId/file/$inoInt';
    downloadUrl = '$serverUrl/api/items/$libraryItemId/download?token=$token';
    localDirPath = await getLocalFilePath(getAudioFile: false);
  }

  Future<String> getLocalFilePath({required bool getAudioFile}) async {
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
    if (kDebugMode) {
      print('No audio file found');
    }

    // If no audio file is found, return an empty string
    return '';
  }

  String getChapterName(double startingPositionTime) {
    for (final chapter in chapters) {
      chapter as Map<String, dynamic>;
      final start = chapter['start'] as num;
      final end = chapter['end'] as num;
      if (startingPositionTime >= start && startingPositionTime <= end) {
        return chapter['title'] as String;
      }
    }
    return 'None found';
  }

  String getInoInt(Map<String, dynamic> resJson) {
    if (resJson['libraryItem'] is Map<String, dynamic> &&
        // ignore: avoid_dynamic_calls
        resJson['libraryItem']['libraryFiles'] is List<dynamic>) {
      final libraryItem = resJson['libraryItem'] as Map<String, dynamic>;
      final libraryFiles = libraryItem['libraryFiles'] as List<dynamic>;
      final audioFile = libraryFiles.firstWhere(
        (file) {
          file as Map<String, dynamic>;
          if (file['fileType'] == 'audio') {
            return true;
          } else {
            return false;
          }
        },
      ) as Map<String, dynamic>?;
      if (audioFile != null) {
        return audioFile['ino'] as String;
      }
    }
    return '';
  }

  Future<Uri> getAudioSourceUri() async {
    final localAudioFile = await getLocalFilePath(getAudioFile: true);
    if (localAudioFile != '') {
      // If the local file path is not empty, return a file URI
      final localAudioFile = await getLocalFilePath(getAudioFile: true);
      if (kDebugMode) {
        print('LAF: $localAudioFile');
      }
      return Uri.file(localAudioFile);
    } else {
      if (kDebugMode) {
        print('Online audio path');
      }
      // If the local file path is empty, return an online URI
      return Uri.parse(onlineAudioUrl);
    }
  }

  Future<Map<String, String>?> getAudioSourceHeaders() async {
    final localAudioFile = await getLocalFilePath(getAudioFile: true);

    if (localAudioFile != '') {
      // If the local file path is not empty, return an empty map
      return null;
    } else {
      // If the local file path is empty, return a map with the session ID
      return <String, String>{
        'Authorization': 'Bearer $token',
      };
    }
  }

  Future<void> downloadFile() async {
    isDownloading = true;
    final httpClient = http.Client();
    final request = http.Request('GET', Uri.parse(downloadUrl));
    final response = await httpClient.send(request);

    if (response.statusCode == 200) {
      // Save the file to the device
      // Downloaded file is a .zip file

      final folderPath = await getLocalFilePath(getAudioFile: false);
      final zipFilePath = '$folderPath/$libraryItemId.zip';

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

      if (kDebugMode) {
        print('Downloading the file');
      }

      // Download the zip file by streaming
      final zipFile = File(zipFilePath);
      await response.stream.pipe(zipFile.openWrite());

      if (kDebugMode) {
        print('Downloaded the file');
        print('Unzipping the file');
      }

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
      if (kDebugMode) {
        print('Downloaded and unzipped the file');
      }
    } else {
      if (kDebugMode) {
        print('Failed to download the file');
      }
    }
    isDownloading = false;
  }

  Future<void> deleteMedia() async {
    final folderPath = await getLocalFilePath(getAudioFile: false);
    final dir = Directory(folderPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }

  bool _isZipFile(File zipFile) {
    return zipFile.path.toLowerCase().endsWith('.zip');
  }

  Stream<Duration> get positionStream {
    return Stream.periodic(const Duration(seconds: 1), (_) => player.position);
  }

  String getTimeLeft() {
    var hours = 0;
    var minutes = 0;
    var seconds = 0;
    final timePlayed = player.position.inSeconds;
    if (chapters.isNotEmpty) {
      for (final chapter in chapters) {
        chapter as Map<String, dynamic>;
        final start = chapter['start'];
        final end = chapter['end'];
        if (timePlayed >= (start as num) && timePlayed <= (end as num)) {
          final remainingSeconds = (end - timePlayed).floor();
          hours = remainingSeconds ~/ 3600.0;
          minutes = (remainingSeconds % 3600) ~/ 60;
          seconds = remainingSeconds % 60;
        }
      }
    } else {
      hours = timePlayed ~/ 3600.0;
      minutes = (timePlayed % 3600) ~/ 60;
      seconds = timePlayed % 60;
    }
    // ignore: lines_longer_than_80_chars
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> seekToPrevious() async {
    if (player.hasPrevious) {
      await player.seekToPrevious();
    } else {
      chapterName = getChapterName(player.position.inSeconds.toDouble());
      final currentChapterIndex = chapters.indexWhere((chapter) {
        chapter as Map<String, dynamic>;
        return chapter['title'] == chapterName;
      });
      if (currentChapterIndex > 0) {
        final previousChapter =
            chapters[currentChapterIndex - 1] as Map<String, dynamic>;
        await player
            .seek(Duration(seconds: (previousChapter['start'] as num).round()));
        chapterName = previousChapter['title'] as String;
      }
    }
  }

  Future<void> seekToNext() async {
    if (player.hasNext) {
      await player.seekToNext();
    } else {
      chapterName = getChapterName(player.position.inSeconds.toDouble());
      final currentChapterIndex = chapters.indexWhere((chapter) {
        chapter as Map<String, dynamic>;
        return chapter['title'] == chapterName;
      });
      if (currentChapterIndex < chapters.length - 1) {
        final nextChapter =
            chapters[currentChapterIndex + 1] as Map<String, dynamic>;
        await player
            .seek(Duration(seconds: (nextChapter['start'] as num).round()));
        chapterName = nextChapter['title'] as String;
      }
    }
  }

  Future<void> seekTo(int position) async {
    await player.seek(Duration(seconds: position));
  }

  void updateChapterNameAndDuration(ValueNotifier<String> timeLeftNotifier) {
    chapterName = getChapterName(player.position.inSeconds.toDouble());
    final timeLeft = getTimeLeft();
    if (timeLeftNotifier.value != timeLeft) {
      timeLeftNotifier.value = timeLeft;
    }
    if (timeLeftNotifier.value == '00:00:00') {
      chapterName = getChapterName(player.position.inSeconds + 5);
    }
  }

  Future<void> togglePlayPause() async {
    if (isPlaying) {
      await player.pause();
      isPlaying = false;
    } else {
      await player.play();
      isPlaying = true;
    }
  }

  Future<void> checkAndSetAudioSource() async {
    final playerAudioSource = await getAudioSourceUri();
    final playerHeaders = await getAudioSourceHeaders();

    // stop the player
    await player.stop();

    // sync the current session data
    await syncOpenSession();

    await player.setAudioSource(
      AudioSource.uri(
        playerAudioSource,
        headers: playerHeaders,
        tag: MediaItem(
          id: libraryItemId,
          title: chapterName,
          album: bookTitle,
        ),
      ),
      initialPosition: Duration(seconds: startingPositionTime.round()),
      preload: false,
    );
  }

  Future<void> syncOpenSession({
    bool close = false,
  }) async {
    if (sessionId.isNotEmpty) {
      final sessionUri =
          '$serverUrl/api/session/$sessionId/${close ? 'close' : 'sync'}';
      final timeListened =
          player.position.inSeconds.toDouble() - startingPositionTime;
      final sessionBody = <String, double>{
        'currentTime': player.position.inSeconds.toDouble(),
        'timeListened': timeListened,
        'duration': duration,
      };
      try {
        // If close is true, then we are closing the session
        final closeResponse = await http.post(
          Uri.parse(sessionUri),
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(sessionBody),
        );
        if (closeResponse.statusCode != 200) {
          return;
        }
        // update the starting position time
        startingPositionTime = player.position.inSeconds.toDouble();
      } catch (e) {
        if (kDebugMode) {
          print('Error syncing session: $e');
        }
      }
    }
  }
}
