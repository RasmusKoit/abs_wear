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

  /// Completes when the previously opened book has released its player and
  /// closed its session. just_audio_background supports a single player, and
  /// a new session must not start before the old one saved its position.
  static Future<void> _previousClose = Future.value();

  /// Completes once the last closed player has saved its final position
  /// (bounded, so callers never wait forever).
  static Future<void> get lastClose =>
      _previousClose.timeout(const Duration(seconds: 45), onTimeout: () {});

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

  /// Position in the whole book, across all audio files. While audio is
  /// loaded this also records the last known position, so a stop, error or
  /// reload (all of which make the player idle) can't rewind progress.
  double get bookPosition {
    // While loading (or with a seek queued until loading ends) the player
    // reports its initial position, not where the user asked to be.
    if (!_audioLoaded ||
        _queuedSeeks > 0 ||
        player.processingState == ProcessingState.loading) {
      return _pendingPosition;
    }
    final index = player.currentIndex ?? 0;
    final offset = index < tracks.length ? tracks[index].startOffset : 0;
    return _pendingPosition = offset + player.position.inMilliseconds / 1000;
  }

  /// Real listening time (wall clock while audio is actually playing, not
  /// buffering or finished), for session stats.
  final Stopwatch _listenClock = Stopwatch();
  Duration _reportedListening = Duration.zero;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<PlayerException>? _errorSub;
  bool _wasPlaying = false;

  /// Seeks waiting for loading to finish (just_audio drops them otherwise).
  int _queuedSeeks = 0;
  int _seekSeq = 0;

  /// True while sources are swapped; the stop/start it causes is not a
  /// user pause and must not sync a transient position.
  bool _reloading = false;

  /// Set after a playback error: the native player is idle and must be
  /// reloaded before it can play again.
  bool _needsReload = false;

  /// Called with a short message when playback fails (e.g. network loss).
  void Function(String message)? onPlaybackError;

  /// Serialises syncs so overlapping calls don't double-report time.
  Future<void> _syncChain = Future.value();

  void _notify() {
    if (!_closed) notifyListeners();
  }

  /// Emits the book position about four times a second.
  Stream<double> get bookPositionStream =>
      Stream.periodic(const Duration(milliseconds: 250), (_) => bookPosition);

  /// Index of the last chapter starting at or before [time] (so gaps
  /// between chapters belong to the previous one), or -1 before the first.
  int chapterIndexAt(double time) {
    var index = -1;
    for (var i = 0; i < chapters.length; i++) {
      // Seeks are rounded to milliseconds, so allow a little slack or a seek
      // to a chapter start could land just before it.
      if (chapters[i].start <= time + _chapterSlack) index = i;
    }
    return index;
  }

  static const _chapterSlack = 0.01;

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

    try {
      // Let the previous book finish closing (bounded, it has its own
      // request timeout) so its final position is saved first.
      // Worst case: a queued sync (20 s) plus the close request (20 s).
      await _previousClose.timeout(
        const Duration(seconds: 45),
        onTimeout: () {},
      );
      if (_closed) return false;
      final response = await _client
          .post(
            Uri.parse('$serverUrl/api/items/$libraryItemId/play'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: await _deviceInfoBody(),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return false;

      _applySession(jsonDecode(response.body) as Map<String, dynamic>);
      if (_closed) {
        // The page went away while the session was starting.
        unawaited(_closeOrphanSession());
        return false;
      }
      if (tracks.isEmpty) return false;
      await _loadSources(initialTime: _lastSyncedTime);
    } on Object catch (e) {
      // Offline, timeout, or an unexpected response shape.
      debugPrint('Could not start playback: $e');
      return false;
    }
    if (_closed) {
      unawaited(_closeOrphanSession());
      return false;
    }
    _stateSub = player.playerStateStream.listen(_onPlayerState);
    _errorSub = player.errorStream.listen(_onPlayerError);
    isLoaded = true;
    _notify();
    return true;
  }

  void _onPlayerState(PlayerState state) {
    final audible =
        state.playing && state.processingState == ProcessingState.ready;
    audible ? _listenClock.start() : _listenClock.stop();
    if (state.processingState == ProcessingState.completed && state.playing) {
      // End of the book: stop so the UI shows play and the pause syncs.
      unawaited(player.pause());
    }
    // Any pause (button, notification, headphones unplugged, audio focus
    // loss) saves progress right away; the app may be killed after it.
    if (_wasPlaying && !state.playing && !_reloading) {
      unawaited(_syncAfterPause());
    }
    _wasPlaying = state.playing;
  }

  /// A pause from the media session (watch controls, headset button) flips
  /// `playing` before the native event with the paused position arrives;
  /// syncing right away would send the position of the last play/seek.
  Future<void> _syncAfterPause() async {
    try {
      await player.playbackEventStream
          .skip(1)
          .first
          .timeout(const Duration(seconds: 1));
    } on Object {
      // No newer event (in-app pauses already carry the position).
    }
    if (!_closed) await syncOpenSession();
  }

  void _onPlayerError(PlayerException e) {
    debugPrint('Playback error: ${e.code} ${e.message}');
    if (_closed) return;
    // The player is idle now, so bookPosition would return a stale cached
    // value; the error event carries the real position.
    final index = e.index ?? player.currentIndex ?? 0;
    if (index < tracks.length) {
      _pendingPosition =
          tracks[index].startOffset + player.position.inMilliseconds / 1000;
    }
    _needsReload = true;
    unawaited(player.pause());
    onPlaybackError?.call('Playback error. Tap play to retry.');
    _notify();
  }

  /// Closes a session that was started after the player was closed.
  /// Uses its own client because the controller's is already closed.
  Future<void> _closeOrphanSession() async {
    if (sessionId.isEmpty) return;
    final client = http.Client();
    try {
      await client
          .post(
            Uri.parse('$serverUrl/api/session/$sessionId/close'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'currentTime': _lastSyncedTime,
              'timeListened': 0,
              'duration': duration,
            }),
          )
          .timeout(const Duration(seconds: 20));
    } on Object catch (e) {
      debugPrint('Could not close orphan session: $e');
    } finally {
      client.close();
    }
  }

  void _applySession(Map<String, dynamic> json) {
    sessionId = json['id'] as String;
    duration = (json['duration'] as num).toDouble();
    _lastSyncedTime = (json['currentTime'] as num).toDouble();
    _pendingPosition = _lastSyncedTime;
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

  /// Local file for a track. Named by index and inode, not the original
  /// basename, so multi-disc books (CD1/01.mp3, CD2/01.mp3) don't collide.
  File _localFile(String dir, BookTrack track) {
    final dot = track.filename.lastIndexOf('.');
    final ext = dot >= 0 ? track.filename.substring(dot) : '';
    final index = track.index.toString().padLeft(3, '0');
    return File('$dir/${index}_${track.ino}$ext');
  }

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
    final seq = ++_seekSeq;
    if (player.processingState == ProcessingState.loading) {
      // just_audio ignores seeks while loading; apply it once loaded.
      _queuedSeeks++;
      _notify();
      try {
        await player.processingStateStream
            .firstWhere((s) => s != ProcessingState.loading)
            .timeout(const Duration(seconds: 30));
      } on Object {
        return; // Disposed or never loaded; the position stays pending.
      } finally {
        _queuedSeeks--;
      }
      // A newer seek supersedes this one.
      if (_closed || seq != _seekSeq) return;
    }
    await player.seek(
      Duration(milliseconds: (offset * 1000).round()),
      index: index,
    );
    _notify();
  }

  Future<void> seekRelative(double seconds) =>
      seekToBookTime(bookPosition + seconds);

  Future<void> seekToNextChapter() async {
    final i = chapterIndexAt(bookPosition);
    if (i < chapters.length - 1) {
      await seekToBookTime(chapters[i + 1].start);
    }
  }

  /// Restarts the current chapter, or goes to the previous one when within
  /// the first 3 seconds of a chapter.
  Future<void> seekToPreviousChapter() async {
    final pos = bookPosition;
    final i = chapterIndexAt(pos);
    if (i < 0) {
      await seekToBookTime(0);
      return;
    }
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

  /// Pausing syncs progress through the player state listener.
  Future<void> togglePlayPause() async {
    if (player.playing) {
      await player.pause();
      return;
    }
    if (_needsReload) {
      _needsReload = false;
      final pos = bookPosition;
      await player.stop();
      await _loadSources(initialTime: pos);
    }
    unawaited(player.play());
  }

  /// Periodic sync: skipped while paused with nothing new to report.
  Future<void> periodicSync() {
    final idle =
        !player.playing &&
        bookPosition == _lastSyncedTime &&
        _listenClock.elapsed == _reportedListening;
    return idle ? Future.value() : syncOpenSession();
  }

  /// Reports progress to the server. With [close], ends the session.
  /// Calls are serialised so overlapping syncs never double-count time.
  /// [position] overrides the player's position, for callers that are about
  /// to stop or release the player.
  Future<void> syncOpenSession({bool close = false, double? position}) {
    return _syncChain = _syncChain.then(
      (_) => _sync(close: close, position: position),
    );
  }

  Future<void> _sync({required bool close, double? position}) async {
    if (sessionId.isEmpty) return;
    final current = position ?? bookPosition;
    final listened = _listenClock.elapsed - _reportedListening;
    try {
      final response = await _client
          .post(
            Uri.parse(
              '$serverUrl/api/session/$sessionId/${close ? 'close' : 'sync'}',
            ),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'currentTime': current,
              'timeListened': listened.inMilliseconds / 1000,
              'duration': duration,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        _lastSyncedTime = current;
        _reportedListening += listened;
      }
    } on Object catch (e) {
      debugPrint('Error syncing session: $e');
    }
  }

  /// Downloads every audio file of the book, streaming each to disk and
  /// reporting progress through [downloadProgress]. Returns true on success.
  Future<bool> downloadBook() async {
    if (isDownloading || tracks.isEmpty) return false;
    isDownloading = true;
    downloadProgress.value = 0;
    _notify();

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
            if (_closed) throw const HttpException('Player closed');
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
      if (!_closed) downloadProgress.value = null;
      _notify();
    }
    if (success && !_closed) await reloadSources();
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
    // Don't wait for the sync: it may be queued behind a slow one, and the
    // user may pause or seek meanwhile.
    unawaited(syncOpenSession(position: pos));
    _needsReload = false;
    _reloading = true;
    try {
      await player.stop();
      await _loadSources(initialTime: pos);
    } finally {
      _reloading = false;
    }
    if (wasPlaying) unawaited(player.play());
    _notify();
  }

  /// Closes the session on the server (saving the final position) and then
  /// releases the player. Safe to call without awaiting from dispose().
  Future<void> close() {
    if (_closed) return _previousClose;
    _closed = true;
    return _previousClose = _close();
  }

  Future<void> _close() async {
    try {
      // Record the final position, then release the player right away so
      // the next book can start; the close request uses the recorded one.
      final position = bookPosition;
      _listenClock.stop();
      await _stateSub?.cancel();
      await _errorSub?.cancel();
      await player.dispose();
      // Before the book loaded, setupPlayer closes the session itself with
      // the server's position; closing here could send position 0.
      if (isLoaded) {
        await syncOpenSession(close: true, position: position);
      }
    } on Object catch (e) {
      debugPrint('Error closing player: $e');
    } finally {
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
