// audio_player.dart
// Audio player controller: playback sessions, multi-file books, chapter
// navigation, progress sync and offline downloads.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';

/// One audio file of a library item. Multi-file books have several, each
/// starting at [startOffset] seconds into the book.
@immutable
class BookTrack {
  const BookTrack({
    required this.index,
    required this.startOffset,
    required this.duration,
    required this.contentUrl,
    required this.filename,
    required this.ino,
    required this.size,
  });

  factory BookTrack.fromJson(
    Map<String, dynamic> json,
    Map<String, int> sizesByIno,
  ) {
    final contentUrl = json['contentUrl'] as String;
    final ino = contentUrl.split('/').last;
    final metadata = json['metadata'] as Map<String, dynamic>? ?? const {};
    return BookTrack(
      index: (json['index'] as num).toInt(),
      startOffset: (json['startOffset'] as num).toDouble(),
      duration: (json['duration'] as num).toDouble(),
      contentUrl: contentUrl,
      filename: metadata['filename'] as String? ?? '$ino.audio',
      ino: ino,
      size: sizesByIno[ino] ?? 0,
    );
  }

  final int index;
  final double startOffset;
  final double duration;
  final String contentUrl;
  final String filename;
  final String ino;
  final int size;

  double get end => startOffset + duration;
}

@immutable
class BookChapter {
  const BookChapter({
    required this.start,
    required this.end,
    required this.title,
  });

  factory BookChapter.fromJson(Map<String, dynamic> json) => BookChapter(
    start: (json['start'] as num).toDouble(),
    end: (json['end'] as num).toDouble(),
    title: json['title'] as String? ?? '',
  );

  final double start;
  final double end;
  final String title;
}

class AudioPlayerController extends ChangeNotifier {
  AudioPlayerController({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;
  final AudioPlayer player = AudioPlayer();

  List<BookTrack> tracks = [];
  List<BookChapter> chapters = [];
  String sessionId = '';
  String bookTitle = '';
  String libraryItemId = '';
  String serverUrl = '';
  String token = '';

  /// Total book length in seconds.
  double duration = 0;

  /// Book position (seconds) at the last successful sync with the server.
  double _lastSyncedTime = 0;

  bool isLoaded = false;
  bool isDownloading = false;

  /// 0..1 while downloading, null otherwise.
  final ValueNotifier<double?> downloadProgress = ValueNotifier(null);

  bool _closed = false;

  /// Where the player should be while its audio is not loaded yet. With
  /// `preload: false` the player reports 0 until playback starts, which
  /// would otherwise sync position 0 and wipe the user's progress.
  double _pendingPosition = 0;

  bool get _audioLoaded => player.processingState != ProcessingState.idle;

  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $token'};

  /// Position in the whole book, across all audio files.
  double get bookPosition {
    if (!_audioLoaded) return _pendingPosition;
    final index = player.currentIndex ?? 0;
    final offset = index < tracks.length ? tracks[index].startOffset : 0;
    return offset + player.position.inMilliseconds / 1000;
  }

  /// Emits the book position about four times a second.
  Stream<double> get bookPositionStream =>
      Stream.periodic(const Duration(milliseconds: 250), (_) => bookPosition);

  int chapterIndexAt(double time) {
    for (var i = 0; i < chapters.length; i++) {
      if (time >= chapters[i].start && time < chapters[i].end) return i;
    }
    // Past the last chapter end (rounding) counts as the last chapter.
    if (chapters.isNotEmpty && time >= chapters.last.end) {
      return chapters.length - 1;
    }
    return -1;
  }

  String get chapterName {
    final i = chapterIndexAt(bookPosition);
    return i >= 0 ? chapters[i].title : '';
  }

  /// Starts a playback session and loads the book into the player.
  /// Returns false if the session could not be started.
  Future<bool> setupPlayer(
    String libItemId,
    String srvUrl,
    String authToken,
  ) async {
    libraryItemId = libItemId;
    serverUrl = srvUrl;
    token = authToken;

    final response = await _client.post(
      Uri.parse('$serverUrl/api/items/$libraryItemId/play'),
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: await _deviceInfoBody(),
    );
    if (response.statusCode != 200) return false;

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _applySession(json);
    await _loadSources(initialTime: _lastSyncedTime);
    isLoaded = true;
    if (!_closed) notifyListeners();
    return true;
  }

  void _applySession(Map<String, dynamic> json) {
    sessionId = json['id'] as String;
    duration = (json['duration'] as num).toDouble();
    _lastSyncedTime = (json['currentTime'] as num).toDouble();
    final metadata = json['mediaMetadata'] as Map<String, dynamic>? ?? {};
    bookTitle = metadata['title'] as String? ?? '';

    final sizesByIno = <String, int>{};
    final item = json['libraryItem'];
    if (item is Map<String, dynamic> && item['libraryFiles'] is List) {
      for (final f
          in (item['libraryFiles'] as List).cast<Map<String, dynamic>>()) {
        final size = (f['metadata'] as Map<String, dynamic>?)?['size'];
        if (size is num) sizesByIno[f['ino'] as String] = size.toInt();
      }
    }

    tracks =
        (json['audioTracks'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map((t) => BookTrack.fromJson(t, sizesByIno))
            .toList()
          ..sort((a, b) => a.startOffset.compareTo(b.startOffset));
    chapters = (json['chapters'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(BookChapter.fromJson)
        .toList();
  }

  Future<String> _deviceInfoBody() async {
    final info = await DeviceInfoPlugin().androidInfo;
    return jsonEncode({
      'deviceInfo': {
        'clientName': 'ABS Wear',
        'clientVersion': info.version.release,
        'deviceName': info.device,
        'deviceType': 'wearable',
        'sdkVersion': info.version.sdkInt,
        'model': info.model,
        'manufacturer': info.manufacturer == 'unknown'
            ? 'Google'
            : info.manufacturer,
      },
      'mediaPlayer': 'JustAudio',
      'forceDirectPlay': true,
    });
  }

  Future<String> localDirPath() async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/$libraryItemId';
  }

  File _localFile(String dir, BookTrack track) =>
      File('$dir/${track.filename}');

  /// True when every audio file of the book is on the device.
  Future<bool> isDownloaded() async {
    if (tracks.isEmpty) return false;
    final dir = await localDirPath();
    for (final t in tracks) {
      if (!_localFile(dir, t).existsSync()) return false;
    }
    return true;
  }

  /// (Re)loads all tracks into the player, preferring local files, and
  /// positions it at [initialTime] seconds into the book.
  Future<void> _loadSources({required double initialTime}) async {
    final local = await isDownloaded();
    final dir = await localDirPath();
    final sources = [
      for (final t in tracks)
        AudioSource.uri(
          local
              ? Uri.file(_localFile(dir, t).path)
              : Uri.parse('$serverUrl${t.contentUrl}'),
          headers: local ? null : _authHeaders,
          tag: MediaItem(
            id: '$libraryItemId/${t.index}',
            title: bookTitle,
            album: bookTitle,
          ),
        ),
    ];
    final (index, offset) = _trackAt(initialTime);
    _pendingPosition = initialTime;
    await player.setAudioSources(
      sources,
      initialIndex: index,
      initialPosition: Duration(milliseconds: (offset * 1000).round()),
      preload: false,
    );
  }

  /// Track index and position within that track for a book time.
  (int, double) _trackAt(double time) {
    for (var i = 0; i < tracks.length; i++) {
      if (time < tracks[i].end || i == tracks.length - 1) {
        final offset = (time - tracks[i].startOffset).clamp(
          0,
          tracks[i].duration,
        );
        return (i, offset.toDouble());
      }
    }
    return (0, 0);
  }

  Future<void> seekToBookTime(double time) async {
    final clamped = time.clamp(0, duration).toDouble();
    final (index, offset) = _trackAt(clamped);
    _pendingPosition = clamped;
    await player.seek(
      Duration(milliseconds: (offset * 1000).round()),
      index: index,
    );
    notifyListeners();
  }

  Future<void> seekRelative(double seconds) =>
      seekToBookTime(bookPosition + seconds);

  Future<void> seekToNextChapter() async {
    final i = chapterIndexAt(bookPosition);
    if (i >= 0 && i < chapters.length - 1) {
      await seekToBookTime(chapters[i + 1].start);
    }
  }

  /// Restarts the current chapter, or goes to the previous one when within
  /// the first 3 seconds of a chapter.
  Future<void> seekToPreviousChapter() async {
    final pos = bookPosition;
    final i = chapterIndexAt(pos);
    if (i < 0) return seekToBookTime(0);
    final target = (pos - chapters[i].start < 3 && i > 0)
        ? chapters[i - 1].start
        : chapters[i].start;
    await seekToBookTime(target);
  }

  /// Time left in the current chapter (or the book if it has none).
  Duration get timeLeft {
    final pos = bookPosition;
    final i = chapterIndexAt(pos);
    final end = i >= 0 ? chapters[i].end : duration;
    final seconds = (end - pos).clamp(0, double.infinity);
    return Duration(seconds: seconds.floor());
  }

  Future<void> togglePlayPause() async {
    if (player.playing) {
      await player.pause();
      unawaited(syncOpenSession());
    } else {
      unawaited(player.play());
    }
  }

  /// Reports progress to the server. With [close], ends the session.
  Future<void> syncOpenSession({bool close = false}) async {
    if (sessionId.isEmpty || !isLoaded) return;
    final current = bookPosition;
    final listened = (current - _lastSyncedTime).clamp(0, double.infinity);
    try {
      final response = await _client.post(
        Uri.parse(
          '$serverUrl/api/session/$sessionId/${close ? 'close' : 'sync'}',
        ),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'currentTime': current,
          'timeListened': listened,
          'duration': duration,
        }),
      );
      if (response.statusCode == 200) _lastSyncedTime = current;
    } on Exception catch (e) {
      debugPrint('Error syncing session: $e');
    }
  }

  /// Downloads every audio file of the book, streaming each to disk and
  /// reporting progress through [downloadProgress]. Returns true on success.
  Future<bool> downloadBook() async {
    if (isDownloading || tracks.isEmpty) return false;
    isDownloading = true;
    downloadProgress.value = 0;
    notifyListeners();

    final dir = Directory(await localDirPath());
    final totalBytes = tracks.fold<int>(0, (sum, t) => sum + t.size);
    var receivedBytes = 0;
    var success = false;
    try {
      dir.createSync(recursive: true);
      for (final (i, t) in tracks.indexed) {
        final target = _localFile(dir.path, t);
        if (target.existsSync() &&
            target.lengthSync() == t.size &&
            t.size > 0) {
          receivedBytes += t.size;
          continue;
        }
        final request = http.Request(
          'GET',
          Uri.parse(
            '$serverUrl/api/items/$libraryItemId/file/${t.ino}/download',
          ),
        )..headers.addAll(_authHeaders);
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode} for ${t.filename}');
        }
        final part = File('${target.path}.part');
        final sink = part.openWrite();
        try {
          await for (final chunk in response.stream) {
            sink.add(chunk);
            receivedBytes += chunk.length;
            downloadProgress.value = totalBytes > 0
                ? (receivedBytes / totalBytes).clamp(0, 1)
                : (i + 1) / tracks.length;
          }
        } finally {
          await sink.close();
        }
        part.renameSync(target.path);
      }
      success = true;
    } on Exception catch (e) {
      debugPrint('Download failed: $e');
    } finally {
      isDownloading = false;
      downloadProgress.value = null;
      if (!_closed) notifyListeners();
    }
    if (success) await reloadSources();
    return success;
  }

  Future<void> deleteDownload() async {
    final dir = Directory(await localDirPath());
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    await reloadSources();
  }

  /// Reloads the player (e.g. after a download or delete) keeping the
  /// current position and play state.
  Future<void> reloadSources() async {
    final wasPlaying = player.playing;
    final pos = bookPosition;
    await player.stop();
    await syncOpenSession();
    await _loadSources(initialTime: pos);
    if (wasPlaying) unawaited(player.play());
    if (!_closed) notifyListeners();
  }

  /// Closes the session on the server (saving the final position) and then
  /// releases the player. Safe to call without awaiting from dispose().
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await player.pause();
      await syncOpenSession(close: true);
    } finally {
      await player.dispose();
      _client.close();
      downloadProgress.dispose();
      super.dispose();
    }
  }
}

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}
