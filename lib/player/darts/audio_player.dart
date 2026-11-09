// audio_player.dart
// Audio player controller: playback sessions, multi-file books, chapter
// navigation, progress sync and offline downloads.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:abs_wear/player/darts/download_keep_alive.dart';
import 'package:abs_wear/player/darts/network_lock.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    this.mimeType,
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
      mimeType: json['mimeType'] as String?,
    );
  }

  final int index;
  final double startOffset;
  final double duration;
  final String contentUrl;
  final String filename;
  final String ino;
  final int size;

  /// As the server reports it; null in sessions saved by older versions.
  final String? mimeType;

  double get end => startOffset + duration;

  /// An HLS playlist the server remuxes the book into, not a file.
  bool get isHls => contentUrl.contains('.m3u8');

  Map<String, dynamic> toJson() => {
    'index': index,
    'startOffset': startOffset,
    'duration': duration,
    'contentUrl': contentUrl,
    'metadata': {'filename': filename},
    'mimeType': ?mimeType,
  };

  /// Streamed from the file as is, without the server remuxing it to HLS.
  bool get directPlayable {
    final type = mimeType;
    if (type != null) {
      return AudioPlayerController.directPlayMimeTypes.contains(type);
    }
    final name = filename.toLowerCase();
    return !const ['.m4b', '.m4a', '.mp4', '.aac'].any(name.endsWith);
  }
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

enum DownloadResult { done, noSpace, failed, canceled }

/// Thrown inside [AudioPlayerController.downloadBook] when the user cancels.
class _DownloadCanceled implements Exception {
  const _DownloadCanceled();
}

class AudioPlayerController extends ChangeNotifier {
  AudioPlayerController({http.Client? client})
    : _client = client ?? _newClient(),
      _injectedClient = client;

  static http.Client _newClient() =>
      IOClient(HttpClient()..idleTimeout = _idleTimeout);

  /// A client passed in (tests): used for downloads too, never replaced.
  final http.Client? _injectedClient;

  /// Shorter than the server's keep-alive (Node's default is 5 s), so a
  /// request never goes out on a connection the server is closing ("Connection
  /// closed before full header was received").
  static const _idleTimeout = Duration(seconds: 3);

  /// Completes when the previously opened book has released its player and
  /// closed its session. just_audio_background supports a single player, and
  /// a new session must not start before the old one saved its position.
  static Future<void> _previousClose = Future.value();

  /// Completes once the last closed player has saved its final position
  /// (bounded, so callers never wait forever).
  static Future<void> get lastClose =>
      _previousClose.timeout(const Duration(seconds: 45), onTimeout: () {});

  /// Local progress keys of books open in a player, with how many players
  /// have each open; [pushLocalProgress] leaves those to the player. Counted,
  /// because a reopened book registers before the old player has closed.
  static final Map<String, int> _openKeys = {};

  /// The key this controller registered in [_openKeys], if any.
  String? _openKey;

  /// The running [pushLocalProgress], so runs don't overlap and a player
  /// starts only after a push of its book finished.
  static Future<void> _pushing = Future.value();

  final http.Client _client;
  final AudioPlayer player = AudioPlayer(
    // The default 50 s buffer runs dry within a minute when the network
    // drops (e.g. the watch switches from Wi-Fi to Bluetooth with the
    // screen off). Audiobooks are low bitrate: buffer up to 15 min, at most
    // 16 MB. Loading resumes only below 3 min, so the radio fetches about
    // 12 min in one burst and then sleeps (min == max refilled one segment
    // at a time and kept the radio awake for the whole book). ExoPlayer
    // multiplies the minimum by the speed: at 2.5x it is 7.5 min, still
    // well below the maximum.
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(minutes: 3),
        maxBufferDuration: Duration(minutes: 15),
        targetBufferBytes: 16 * 1024 * 1024,
      ),
    ),
  );

  /// The loaded audio is streamed from the server (not downloaded).
  bool _streaming = false;

  /// The book's audio files (what a download saves).
  List<BookTrack> tracks = [];

  /// What the server streams: [tracks] for direct play, or one HLS track
  /// for the whole book when the server remuxes it.
  List<BookTrack> _streamTracks = [];

  /// The tracks loaded in the player: [tracks] when playing downloaded
  /// files, else [_streamTracks]. Player indexes refer to this list.
  List<BookTrack> _playing = [];
  List<BookChapter> chapters = [];
  String sessionId = '';

  /// Whether the server session was started with direct play; a session
  /// started again after the server forgot it asks for the same.
  bool _directPlay = false;
  String bookTitle = '';

  /// Author (or, for an episode, the podcast), for the media notification.
  String bookAuthor = '';

  /// The item has cover art on the server.
  bool _hasCover = true;
  String libraryItemId = '';

  /// Set when playing a podcast episode ([libraryItemId] is the podcast).
  String? episodeId;

  /// The item (and episode) part of play and progress URLs.
  String get _mediaPath => _pathFor(libraryItemId, episodeId);

  static String _pathFor(String itemId, String? episodeId) =>
      episodeId == null ? itemId : '$itemId/$episodeId';
  String serverUrl = '';
  String token = '';

  /// Logged-in user; local progress is kept per user.
  String user = '';

  /// Total book length in seconds.
  double duration = 0;

  /// Book position (seconds) at the last successful sync with the server.
  double _lastSyncedTime = 0;

  bool isLoaded = false;
  bool isDownloading = false;

  /// Playing a downloaded book without a server session (no network).
  /// Progress is kept on the watch and sent the next time the book opens
  /// online.
  bool isOffline = false;

  /// What [_startOffline] needs to rebuild the session without the
  /// server; saved next to downloaded files.
  Map<String, dynamic>? _sessionMeta;

  /// Listening time from offline play, added to the next successful sync.
  Duration _carriedListening = Duration.zero;

  /// What the local progress file holds, so unchanged progress isn't
  /// rewritten with a newer timestamp (it would then beat newer progress
  /// from another device).
  double? _savedTime;
  Duration _savedListened = Duration.zero;

  /// 0..1 while downloading, null otherwise.
  final ValueNotifier<double?> downloadProgress = ValueNotifier(null);

  /// Playback speeds offered; the choice is kept for all books.
  static const speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5];
  static const _speedKey = 'playbackSpeed';

  double get speed => player.speed;

  /// Steps the speed up ([step] 1) or down (-1) through [speeds].
  Future<void> changeSpeed(int step) async {
    var i = speeds.indexWhere((s) => s >= speed - 0.01);
    if (i < 0) i = speeds.length - 1;
    final next = speeds[(i + step).clamp(0, speeds.length - 1)];
    await player.setSpeed(next);
    _notify();
    try {
      await (await SharedPreferences.getInstance()).setDouble(_speedKey, next);
    } on Object catch (e) {
      debugPrint('Could not save speed: $e');
    }
  }

  Future<void> _applySavedSpeed() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getDouble(
        _speedKey,
      );
      if (saved != null && saved > 0) await player.setSpeed(saved);
    } on Object catch (e) {
      debugPrint('Could not restore speed: $e');
    }
  }

  /// Sleep timer choices; tapping cycles through them, then off.
  static const sleepOptions = [
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(minutes: 60),
  ];

  /// Listening time left before playback pauses; null when off. Counts
  /// down only while audio is actually heard (not paused or buffering).
  final ValueNotifier<Duration?> sleepRemaining = ValueNotifier(null);
  Timer? _sleepTimer;
  final Stopwatch _sleepClock = Stopwatch();
  Duration _sleepTarget = Duration.zero;

  /// Index in [sleepOptions] of the running timer; -1 when off.
  int _sleepChoice = -1;

  /// Moves to the option after the chosen one (or off after the last).
  void cycleSleepTimer() {
    final next = _sleepChoice + 1;
    setSleepTimer(next < sleepOptions.length ? next : null);
  }

  /// Starts the timer with [sleepOptions] at [choice], or turns it off.
  void setSleepTimer(int? choice) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepClock
      ..stop()
      ..reset();
    _sleepChoice = choice ?? -1;
    if (_closed) return;
    if (choice == null) {
      sleepRemaining.value = null;
      return;
    }
    _sleepTarget = sleepOptions[choice];
    sleepRemaining.value = _sleepTarget;
    if (_audible) {
      _sleepClock.start();
      _startSleepTick();
    }
  }

  /// Counts the sleep timer down while audio plays; paused, the clock and
  /// the tick stop (no wakeups while nothing changes). The clock measures
  /// time; the tick only shows it (late ticks don't slow the timer down).
  void _startSleepTick() {
    _sleepTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final left = _sleepTarget - _sleepClock.elapsed;
      if (left > Duration.zero) {
        sleepRemaining.value = Duration(seconds: left.inSeconds + 1);
        return;
      }
      setSleepTimer(null);
      unawaited(player.pause());
    });
  }

  bool get _audible =>
      player.playing && player.processingState == ProcessingState.ready;

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
    final offset = index < _playing.length ? _playing[index].startOffset : 0;
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

  /// [_loadSources] is waiting for the server's stream; seeks only move
  /// the pending position meanwhile.
  bool _awaitingStream = false;
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
    String authToken, {
    String userName = '',
    String? episodeId,
  }) async {
    libraryItemId = libItemId;
    this.episodeId = episodeId;
    serverUrl = srvUrl;
    token = authToken;
    user = userName;
    if (_openKey == null) {
      final key = _openKey = _localKey;
      _openKeys.update(key, (n) => n + 1, ifAbsent: () => 1);
    }

    try {
      // Let the previous book finish closing (bounded, it has its own
      // request timeout) so its final position is saved first.
      // Worst case: a queued sync (20 s) plus the close request (20 s).
      await _previousClose.timeout(
        const Duration(seconds: 45),
        onTimeout: () {},
      );
      // A push of offline progress for this book must land first.
      await _pushing.timeout(const Duration(seconds: 25), onTimeout: () {});
      if (_closed) return false;
      // A downloaded book doesn't wait long for a slow network.
      final canPlayOffline = _metaFile(await localDirPath()).existsSync();
      // A downloaded book plays its files; podcast episodes are small
      // enough to play directly.
      _directPlay = canPlayOffline || episodeId != null;
      final response = await _postPlay(
        directPlay: _directPlay,
        timeout: Duration(seconds: canPlayOffline ? 5 : 20),
      );
      if (response.statusCode == 401) return false; // Log in again.
      if (response.statusCode != 200) {
        if (!await _startOffline()) return false;
      } else {
        _applySession(jsonDecode(response.body) as Map<String, dynamic>);
        if (_closed) {
          // The page went away while the session was starting.
          unawaited(_closeOrphanSession());
          return false;
        }
        if (_streamTracks.isEmpty) {
          unawaited(_closeOrphanSession());
          return false;
        }
        await _resumeLocalProgress();
        await _loadSources(initialTime: _pendingPosition);
        if (await isDownloaded()) {
          unawaited(_saveSessionMeta());
          // Downloads from before covers were saved get theirs now.
          final dir = await localDirPath();
          if (_hasCover && !_coverFile(dir).existsSync()) {
            unawaited(_downloadCover(dir));
          }
        }
        // Send progress made offline right away.
        if (_carriedListening > Duration.zero) unawaited(syncOpenSession());
      }
    } on Object catch (e) {
      // No network or timeout: a downloaded book still plays.
      debugPrint('Could not start a server session: $e');
      try {
        if (_closed || !await _startOffline()) return false;
      } on Object catch (e) {
        debugPrint('Could not start offline: $e');
        return false;
      }
    }
    await _applySavedSpeed();
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

  File _metaFile(String dir) => File('$dir/session.json');

  /// Saves the session details next to the downloaded files, so the book
  /// can be opened without a network later.
  Future<void> _saveSessionMeta() async {
    final meta = _sessionMeta;
    if (meta == null) return;
    try {
      final dir = await localDirPath();
      if (!Directory(dir).existsSync()) return;
      await _metaFile(dir).writeAsString(jsonEncode(meta), flush: true);
    } on Object catch (e) {
      debugPrint('Could not save session details: $e');
    }
  }

  /// Rebuilds the session from saved details when the book is downloaded.
  Future<bool> _startOffline() async {
    final file = _metaFile(await localDirPath());
    if (!file.existsSync()) return false;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _applySession({...json, 'id': ''});
    if (tracks.isEmpty || !await isDownloaded()) return false;
    final local = await _readLocalProgress();
    if (local != null) {
      _pendingPosition = _lastSyncedTime = local.time;
      _carriedListening = local.listened;
    }
    isOffline = true;
    await _loadSources(initialTime: _pendingPosition);
    return true;
  }

  /// Progress kept on the watch. `pending` progress (from offline play or a
  /// failed sync) still has to reach the server; otherwise it is the last
  /// synced position of a downloaded book, where offline play resumes.
  /// `listenedMs` is listening time the server hasn't counted yet.
  static Future<Directory> _localProgressDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/offline_progress');
  }

  String get _localKey => _keyFor(serverUrl, user, _mediaPath);

  static String _keyFor(String server, String user, String mediaPath) =>
      '$server|$user|$mediaPath';

  Future<File> _localProgressFile() async {
    final key = _localKey.hashCode.toUnsigned(32);
    return File('${(await _localProgressDir()).path}/$key.json');
  }

  /// Removes all progress kept on the watch (e.g. on logout).
  static Future<void> clearAllLocalProgress() async {
    try {
      final dir = await _localProgressDir();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on Object catch (e) {
      debugPrint('Could not clear local progress: $e');
    }
  }

  /// Sends positions saved offline for books that weren't opened online
  /// since, unless the server has something newer. Call when online.
  /// Listening time stays on the watch until the book is next played
  /// online (the progress API can't add listening time).
  static Future<void> pushLocalProgress(
    String serverUrl,
    String token,
    String user,
  ) {
    return _pushing = _pushing
        .then((_) => _push(serverUrl, token, user))
        .catchError((Object e) {
          debugPrint('Could not push local progress: $e');
        });
  }

  static Future<void> _push(String serverUrl, String token, String user) async {
    // The last closed book may still be saving its final position.
    await lastClose;
    final dir = await _localProgressDir();
    if (!dir.existsSync()) return;
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final client = http.Client();
    try {
      for (final file in dir.listSync().whereType<File>()) {
        try {
          final raw = file.readAsStringSync();
          final json = jsonDecode(raw) as Map<String, dynamic>;
          if (json['server'] != serverUrl || json['user'] != user) continue;
          if (json['pending'] != true) continue;
          final mediaPath = _pathFor(
            json['itemId'] as String,
            json['episodeId'] as String?,
          );
          final key = _keyFor(serverUrl, user, mediaPath);
          if (_openKeys.containsKey(key)) continue;
          final url = Uri.parse('$serverUrl/api/me/progress/$mediaPath');
          final current = await client
              .get(url, headers: headers)
              .timeout(const Duration(seconds: 10));
          final serverJson = current.statusCode == 200
              ? jsonDecode(current.body) as Map<String, dynamic>
              : const <String, dynamic>{};
          final serverUpdated =
              (serverJson['lastUpdate'] as num?)?.toInt() ?? 0;
          final Map<String, dynamic> updated;
          if (serverUpdated <= (json['updatedAt'] as num).toInt()) {
            final time = (json['currentTime'] as num).toDouble();
            final duration = (json['duration'] as num?)?.toDouble() ?? 0;
            final response = await client
                .patch(
                  url,
                  headers: headers,
                  body: jsonEncode({
                    'currentTime': time,
                    if (duration > 0) 'duration': duration,
                    if (duration > 0)
                      'progress': (time / duration).clamp(0.0, 1.0),
                  }),
                )
                .timeout(const Duration(seconds: 10));
            if (response.statusCode != 200) continue;
            updated = {...json, 'pending': false};
          } else {
            // Played elsewhere since: resume offline from there instead.
            updated = {
              ...json,
              'pending': false,
              'currentTime':
                  (serverJson['currentTime'] as num?)?.toDouble() ??
                  json['currentTime'],
              'updatedAt': serverUpdated,
            };
          }
          // Synchronous, so nothing else runs between the check and the
          // write: keep a file a player changed meanwhile.
          if (_openKeys.containsKey(key) ||
              !file.existsSync() ||
              file.readAsStringSync() != raw) {
            continue;
          }
          file.writeAsStringSync(jsonEncode(updated), flush: true);
        } on Object catch (e) {
          debugPrint('Could not push local progress ${file.path}: $e');
        }
      }
    } finally {
      client.close();
    }
  }

  Future<({double time, Duration listened, int updatedAt, bool pending})?>
  _readLocalProgress() async {
    try {
      final file = await _localProgressFile();
      if (!file.existsSync()) return null;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (json['itemId'] != libraryItemId ||
          json['episodeId'] != episodeId ||
          json['user'] != user) {
        return null;
      }
      final local = (
        time: (json['currentTime'] as num).toDouble(),
        listened: Duration(milliseconds: (json['listenedMs'] as num).toInt()),
        updatedAt: (json['updatedAt'] as num).toInt(),
        pending: json['pending'] == true,
      );
      _savedTime = local.time;
      _savedListened = local.listened;
      return local;
    } on Object catch (e) {
      debugPrint('Could not read local progress: $e');
      return null;
    }
  }

  /// Saves progress the server doesn't have yet. Skipped when nothing
  /// changed, so opening a book without playing it doesn't make its old
  /// position look new.
  Future<void> _savePendingProgress(double time, Duration listened) async {
    final saved = _savedTime;
    if (saved != null &&
        (time - saved).abs() < 1 &&
        listened == _savedListened) {
      return;
    }
    await _writeLocalProgress(time, listened, pending: true);
  }

  Future<void> _writeLocalProgress(
    double time,
    Duration listened, {
    required bool pending,
  }) async {
    try {
      final file = await _localProgressFile();
      file.parent.createSync(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'server': serverUrl,
          'user': user,
          'itemId': libraryItemId,
          'episodeId': ?episodeId,
          'duration': duration,
          'currentTime': time,
          'listenedMs': listened.inMilliseconds,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          'pending': pending,
        }),
        flush: true,
      );
      _savedTime = time;
      _savedListened = listened;
    } on Object catch (e) {
      debugPrint('Could not save local progress: $e');
    }
  }

  Future<void> _clearLocalProgress() async {
    _savedTime = null;
    _savedListened = Duration.zero;
    try {
      final file = await _localProgressFile();
      if (file.existsSync()) file.deleteSync();
    } on Object catch (e) {
      debugPrint('Could not clear local progress: $e');
    }
  }

  /// Uses progress made offline unless the server has a newer position
  /// (e.g. the book was played on the phone meanwhile).
  Future<void> _resumeLocalProgress() async {
    final local = await _readLocalProgress();
    if (local == null) return;
    // Listening time from offline play is reported either way.
    _carriedListening = local.listened;
    if (!local.pending) return;
    var serverUpdated = 0;
    try {
      final response = await _client
          .get(
            Uri.parse('$serverUrl/api/me/progress/$_mediaPath'),
            headers: _authHeaders,
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        serverUpdated = (json['lastUpdate'] as num?)?.toInt() ?? 0;
      }
    } on Object catch (e) {
      debugPrint('Could not read server progress: $e');
    }
    if (serverUpdated > local.updatedAt) return; // The next sync replaces it.
    _pendingPosition = local.time;
  }

  void _onPlayerState(PlayerState state) {
    final audible =
        state.playing && state.processingState == ProcessingState.ready;
    audible ? _listenClock.start() : _listenClock.stop();
    if (_sleepChoice >= 0) {
      if (audible) {
        _sleepClock.start();
        _startSleepTick();
      } else {
        _sleepClock.stop();
        _sleepTimer?.cancel();
        _sleepTimer = null;
      }
    }
    // Keep the network up while streaming, also while loading with the
    // screen off.
    unawaited(NetworkLock.set(hold: state.playing && _streaming));
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
    if (index < _playing.length) {
      _pendingPosition =
          _playing[index].startOffset + player.position.inMilliseconds / 1000;
    }
    _needsReload = true;
    unawaited(player.pause());
    onPlaybackError?.call('Playback error. Tap play to retry.');
    _notify();
  }

  /// Closes a session that was started after the player was closed.
  Future<void> _closeOrphanSession() =>
      _closeSessionAt(sessionId, _lastSyncedTime);

  /// Closes session [id] at [position] without reporting listening time.
  /// Uses its own client because the controller's may already be closed.
  Future<void> _closeSessionAt(String id, double position) async {
    if (id.isEmpty) return;
    final client = http.Client();
    try {
      await client
          .post(
            Uri.parse('$serverUrl/api/session/$id/close'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'currentTime': position,
              'timeListened': 0,
              'duration': duration,
            }),
          )
          .timeout(const Duration(seconds: 20));
    } on Object catch (e) {
      debugPrint('Could not close session $id: $e');
    } finally {
      client.close();
    }
  }

  /// Tail of the session replacements ([_restartSession], [_reopenStream]).
  /// They run one at a time: ABS closes a device's other session when one
  /// starts, so overlapping /play calls could kill the session just set up.
  Future<void> _sessionStart = Future.value();

  /// Runs [replace] once the session replacements before it are done.
  Future<T> _replacingSession<T>(Future<T> Function() replace) {
    final result = _sessionStart.then((_) => replace());
    _sessionStart = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Starts a new server session after the server forgot the current one,
  /// as the current one was started. Only its id is used: the player keeps
  /// its position and audio. True when there is a current session to send
  /// to (a new one, or one that replaced the forgotten one meanwhile).
  Future<bool> _restartSession() {
    final id = sessionId;
    return _replacingSession(() async {
      if (_closed) return false;
      // _reopenStream replaced it while this waited: send there.
      if (sessionId != id) return sessionId.isNotEmpty;
      try {
        final response = await _postPlay(
          directPlay: _directPlay,
          timeout: const Duration(seconds: 10),
        );
        if (response.statusCode != 200) return false;
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final newId = json['id'] as String;
        if (_closed) {
          // Closed meanwhile: the queued close saves the position.
          unawaited(_closeSessionAt(newId, bookPosition));
          return false;
        }
        sessionId = newId;
        debugPrint('Server forgot the session; started $sessionId');
        return true;
      } on Object catch (e) {
        debugPrint('Could not restart the session: $e');
        return false;
      }
    });
  }

  void _applySession(Map<String, dynamic> json) {
    final libItem = json['libraryItem'];
    final files =
        libItem is Map<String, dynamic> && libItem['libraryFiles'] is List
        ? (libItem['libraryFiles'] as List).cast<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];
    final libMedia = libItem is Map<String, dynamic> ? libItem['media'] : null;
    // Unknown (no such field) counts as having one.
    _hasCover =
        json['hasCover'] as bool? ??
        !(libMedia is Map<String, dynamic> &&
            libMedia.containsKey('coverPath') &&
            libMedia['coverPath'] == null);
    final sizesByIno = <String, int>{};
    for (final f in files) {
      final size = (f['metadata'] as Map<String, dynamic>?)?['size'];
      if (size is num) sizesByIno[f['ino'] as String] = size.toInt();
    }
    List<BookTrack> parse(Object? list) =>
        (list is List ? list : const <Object?>[])
            .cast<Map<String, dynamic>>()
            .map((t) => BookTrack.fromJson(t, sizesByIno))
            .toList()
          ..sort((a, b) => a.startOffset.compareTo(b.startOffset));
    final streamTracks = parse(json['audioTracks']);
    // An HLS session streams one playlist; the files to download are the
    // item's tracks.
    final hls = streamTracks.any((t) => t.isHls);
    final fileTracks = !hls
        ? streamTracks
        : libMedia is Map<String, dynamic>
        ? parse(libMedia['tracks'])
        : <BookTrack>[];

    final mediaMeta = json['mediaMetadata'];
    _sessionMeta = {
      // For the downloads list.
      'server': serverUrl,
      'itemId': libraryItemId,
      'episodeId': ?episodeId,
      'duration': json['duration'],
      'currentTime': json['currentTime'],
      'displayTitle': json['displayTitle'],
      'displayAuthor': json['displayAuthor'],
      'hasCover': _hasCover,
      'mediaMetadata': {
        'title': mediaMeta is Map<String, dynamic> ? mediaMeta['title'] : null,
      },
      // The files, not an HLS stream: offline play uses these.
      'audioTracks': [for (final t in fileTracks) t.toJson()],
      'chapters': json['chapters'],
      'libraryItem': {
        'libraryFiles': [
          for (final f in files)
            {
              'ino': f['ino'],
              'metadata': {
                'size': (f['metadata'] as Map<String, dynamic>?)?['size'],
              },
            },
        ],
      },
    };
    sessionId = json['id'] as String;
    duration = (json['duration'] as num).toDouble();
    _lastSyncedTime = (json['currentTime'] as num).toDouble();
    _pendingPosition = _lastSyncedTime;
    final metadata = json['mediaMetadata'] as Map<String, dynamic>? ?? {};
    // For an episode this is the episode's title, not the podcast's.
    bookTitle =
        json['displayTitle'] as String? ?? metadata['title'] as String? ?? '';
    bookAuthor = json['displayAuthor'] as String? ?? '';

    tracks = fileTracks;
    _streamTracks = streamTracks;
    chapters = (json['chapters'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(BookChapter.fromJson)
        .toList();
  }

  /// Formats the player streams straight from the file. Not MP4 (m4b,
  /// m4a): the player must download and parse an MP4's whole index before
  /// it can play, which for a long audiobook is tens of MB and can run the
  /// watch out of memory; the server remuxes those to HLS instead. Not ADTS
  /// AAC either, which can't be seeked without reading from the start.
  static const directPlayMimeTypes = [
    'audio/mpeg',
    'audio/flac',
    'audio/x-flac',
    'audio/ogg',
    'audio/opus',
    'audio/wav',
    'audio/x-wav',
    'audio/webm',
  ];

  /// Starts a server session for the book (or episode).
  Future<http.Response> _postPlay({
    required bool directPlay,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    return await _client
        .post(
          Uri.parse(
            '$serverUrl/api/items/$libraryItemId/play'
            '${episodeId == null ? '' : '/$episodeId'}',
          ),
          headers: {..._authHeaders, 'Content-Type': 'application/json'},
          body: await _deviceInfoBody(directPlay: directPlay),
        )
        .timeout(timeout);
  }

  Future<String> _deviceInfoBody({required bool directPlay}) async {
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
      if (directPlay)
        'forceDirectPlay': true
      else
        'supportedMimeTypes': directPlayMimeTypes,
    });
  }

  Future<String> localDirPath() async {
    final docs = await getApplicationDocumentsDirectory();
    // Each episode of a podcast gets its own folder.
    return '${docs.path}/'
        '${episodeId == null ? libraryItemId : '${libraryItemId}_$episodeId'}';
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

  /// True when any downloaded or partly downloaded file is on the device
  /// (so the user can remove the leftovers of a failed download).
  Future<bool> hasLocalFiles() async {
    if (libraryItemId.isEmpty) return false;
    final dir = Directory(await localDirPath());
    return dir.existsSync() && dir.listSync().isNotEmpty;
  }

  /// The server's HLS URLs need no token (they carry the session id), and
  /// without headers just_audio loads them directly instead of through its
  /// local proxy, which would parse the playlist on the UI isolate and keep
  /// a handler per segment (tens of thousands for a long book). Only over
  /// HTTPS: the network security config allows the native player cleartext
  /// HTTP only to the proxy on 127.0.0.1.
  bool get _https => serverUrl.startsWith('https:');

  /// (Re)loads all tracks into the player, preferring local files, and
  /// positions it at [initialTime] seconds into the book.
  Future<void> _loadSources({required double initialTime}) async {
    final local = await isDownloaded();
    _streaming = !local;
    final playing = local ? tracks : _streamTracks;
    final dir = await localDirPath();
    // Cover art for the media notification: the saved copy when there is
    // one, else from the server (the header keeps the token out of the URL).
    // None when there is no cover, or offline without a saved copy (each
    // failed fetch would be retried and logged on every track change).
    final coverFile = _coverFile(dir);
    final cover = coverFile.existsSync()
        ? Uri.file(coverFile.path)
        : _hasCover && !isOffline
        ? Uri.parse('$serverUrl/api/items/$libraryItemId/cover?width=400')
        : null;
    final sources = [
      for (final t in playing)
        AudioSource.uri(
          local
              ? Uri.file(_localFile(dir, t).path)
              : Uri.parse('$serverUrl${t.contentUrl}'),
          headers: local || (t.isHls && _https) ? null : _authHeaders,
          tag: MediaItem(
            id: '$_mediaPath/${t.index}',
            title: bookTitle,
            album: bookTitle,
            artist: bookAuthor.isEmpty ? null : bookAuthor,
            artUri: cover,
            artHeaders: cover == null || cover.scheme == 'file'
                ? null
                : _authHeaders,
          ),
        ),
    ];
    _playing = playing;
    _pendingPosition = initialTime;
    if (!local) {
      // Seeks made while waiting only move the pending position; the audio
      // loads where the last one went.
      _awaitingStream = true;
      try {
        var waitedFor = initialTime;
        await _awaitHlsSegment(waitedFor);
        while (_pendingPosition != waitedFor && !_closed) {
          waitedFor = _pendingPosition;
          await _awaitHlsSegment(waitedFor);
        }
      } finally {
        _awaitingStream = false;
      }
    }
    final (index, offset) = _trackAt(_pendingPosition);
    await player.setAudioSources(
      sources,
      initialIndex: index,
      initialPosition: Duration(milliseconds: (offset * 1000).round()),
      preload: false,
    );
  }

  /// Track index and position within that track for a book time.
  (int, double) _trackAt(double time) {
    for (var i = 0; i < _playing.length; i++) {
      if (time < _playing[i].end || i == _playing.length - 1) {
        final offset = (time - _playing[i].startOffset).clamp(
          0,
          _playing[i].duration,
        );
        return (i, offset.toDouble());
      }
    }
    return (0, 0);
  }

  /// The server's HLS segment length (fixed in Audiobookshelf).
  static const _hlsSegmentSeconds = 6;

  /// [time] (in the single HLS track) is already loaded ahead.
  bool _isBuffered(double time) {
    final position = player.position.inMilliseconds / 1000;
    final buffered = player.bufferedPosition.inMilliseconds / 1000;
    return time >= position && time <= buffered;
  }

  /// Waits, at most 10 s, until the server has made the HLS segment at
  /// [time]. The server answers 404 for a segment it hasn't made yet (and
  /// starts making it there), which the player takes as a fatal error.
  Future<void> _awaitHlsSegment(
    double time, {
    bool Function()? isCurrent,
  }) async {
    final track = _playing.firstOrNull;
    if (track == null || !track.isHls) return;
    final dir = track.contentUrl.substring(
      0,
      track.contentUrl.lastIndexOf('/'),
    );
    final segment = (time / _hlsSegmentSeconds).floor();
    final uri = Uri.parse('$serverUrl$dir/output-$segment.ts');
    final waited = Stopwatch()..start();
    var missing = false;
    while (!_closed &&
        (isCurrent?.call() ?? true) &&
        waited.elapsed < const Duration(seconds: 10)) {
      try {
        final response = await _client
            .head(uri)
            .timeout(const Duration(seconds: 5));
        // Anything but "not made yet" is for the player to handle.
        if (response.statusCode != 404) {
          // A segment that just appeared may still be being written.
          if (missing) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          return;
        }
        missing = true;
      } on Object catch (e) {
        debugPrint('Could not check the stream: $e');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> seekToBookTime(double time) async {
    final clamped = time.clamp(0, duration).toDouble();
    _pendingPosition = clamped;
    final seq = ++_seekSeq;
    if (_awaitingStream) {
      // The audio is about to load; it starts at the pending position.
      _notify();
      return;
    }
    final (index, offset) = _trackAt(clamped);
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
    if (_playing.any((t) => t.isHls) && !_isBuffered(clamped)) {
      // Counts as queued, so the position shows the target meanwhile and
      // further skips add up from it.
      _queuedSeeks++;
      _notify();
      try {
        await _awaitHlsSegment(clamped, isCurrent: () => seq == _seekSeq);
      } finally {
        _queuedSeeks--;
      }
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
    // Real time at the current speed, like the other ABS apps.
    final seconds = (end - pos).clamp(0, double.infinity) / speed;
    return Duration(seconds: seconds.floor());
  }

  /// Pausing syncs progress through the player state listener.
  Future<void> togglePlayPause() async {
    // The audio is being swapped (download added or deleted) and the
    // stopped player shows Play: a tap means play once it is loaded.
    if (_reloading) {
      _playAfterReload = true;
      return;
    }
    final pending = _playAfterReload;
    if (pending != null) {
      // Reloading after an error: a second tap cancels the play.
      _playAfterReload = !pending;
      return;
    }
    if (player.playing) {
      await player.pause();
      return;
    }
    if (_needsReload) {
      _needsReload = false;
      _playAfterReload = true;
      var play = true;
      try {
        final pos = bookPosition;
        await player.stop();
        // The server's HLS stream may be gone (e.g. it restarted); a new
        // session brings a fresh one.
        if (_streamTracks.any((t) => t.isHls) && !await isDownloaded()) {
          await _reopenStream(pos);
        }
        await _loadSources(initialTime: _pendingPosition);
      } finally {
        if (_reloading) {
          // reloadSources (a download finished meanwhile) is swapping the
          // audio again; it applies the play once it is done.
          play = false;
        } else {
          play = _playAfterReload ?? false;
          _playAfterReload = null;
        }
      }
      if (!play || _closed) return;
    }
    unawaited(player.play());
  }

  /// While the audio reloads (play after an error, or [reloadSources]):
  /// whether to play once it is loaded.
  bool? _playAfterReload;

  /// Failed syncs in a row, and when a paused player may retry: 2, 4, 8 …
  /// up to 30 min, so a paused book left open doesn't post every minute.
  int _failedSyncs = 0;
  DateTime? _retryAt;

  /// Periodic sync: skipped while paused with nothing new to report, or
  /// while paused and backing off after failed syncs.
  Future<void> periodicSync() {
    if (!player.playing) {
      final retryAt = _retryAt;
      if (retryAt != null && DateTime.now().isBefore(retryAt)) {
        return Future.value();
      }
    }
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
    final current = position ?? bookPosition;
    if (sessionId.isEmpty) {
      if (!isOffline) return;
      // No server session: keep progress on the watch until online.
      _carriedListening += _listenClock.elapsed - _reportedListening;
      _reportedListening = _listenClock.elapsed;
      _lastSyncedTime = current;
      await _savePendingProgress(current, _carriedListening);
      return;
    }
    final listened =
        _listenClock.elapsed - _reportedListening + _carriedListening;
    var synced = false;
    final body = jsonEncode({
      'currentTime': current,
      'timeListened': listened.inMilliseconds / 1000,
      'duration': duration,
    });
    Future<http.Response> post() => _client
        .post(
          Uri.parse(
            '$serverUrl/api/session/$sessionId/${close ? 'close' : 'sync'}',
          ),
          headers: {..._authHeaders, 'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 20));
    try {
      final id = sessionId;
      var response = await post();
      // The server forgot the session (e.g. it restarted): every later sync
      // would fail too, so start a new one and send the progress there, once
      // per sync. Not for a close: the pending file below keeps the position
      // for pushLocalProgress. When the session was replaced meanwhile
      // (_reopenStream), just send to the new one.
      // Not once the player is closing either: its queued close then 404s
      // and saves the position as above, within the close's time bound.
      if (response.statusCode == 404 &&
          !close &&
          !_closed &&
          (sessionId != id || await _restartSession()) &&
          !_closed) {
        response = await post();
      }
      if (response.statusCode == 200) {
        synced = true;
        _lastSyncedTime = current;
        _reportedListening = _listenClock.elapsed;
        _carriedListening = Duration.zero;
      }
    } on Object catch (e) {
      debugPrint('Error syncing session: $e');
    }
    if (synced) {
      _failedSyncs = 0;
      _retryAt = null;
    } else {
      _failedSyncs++;
      _retryAt = DateTime.now().add(
        Duration(minutes: min(30, 1 << min(_failedSyncs, 5))),
      );
    }
    if (!synced) {
      // Keep the position on the watch until the server gets it (e.g. the
      // network dropped while listening to a downloaded book).
      await _savePendingProgress(current, listened);
    } else if (await isDownloaded()) {
      // Where offline play resumes next time.
      await _writeLocalProgress(current, Duration.zero, pending: false);
    } else {
      await _clearLocalProgress();
    }
  }

  /// Completes when the running download is canceled.
  Completer<void>? _downloadCancel;

  /// True while the download is bound to the watch's Wi-Fi.
  bool _downloadOnWifi = false;

  /// The running download's own client: opened after the network was
  /// picked, so no pooled connection from before the switch is reused.
  http.Client? _downloadClient;

  void _closeDownloadClient() {
    final client = _downloadClient;
    _downloadClient = null;
    if (client != null && client != _injectedClient) client.close();
  }

  /// False once [close] was called.
  bool get isOpen => !_closed;

  /// Stops the running download. Finished files are kept (the download can
  /// resume, or the leftovers be deleted); the partial file is removed.
  void cancelDownload() {
    final cancel = _downloadCancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  /// Downloads every audio file of the book, streaming each to disk and
  /// reporting progress through [downloadProgress]. Finished files are kept
  /// on failure, so a retry resumes with the next file.
  ///
  /// Keeps going with the screen off (see [DownloadKeepAlive]); the labels
  /// are for its notification.
  Future<DownloadResult> downloadBook({
    String cancelLabel = 'Cancel',
    String channelName = 'Downloads',
  }) async {
    if (isDownloading || tracks.isEmpty) return DownloadResult.failed;
    isDownloading = true;
    downloadProgress.value = 0;
    final cancel = _downloadCancel = Completer<void>();
    _notify();
    // Byte progress only when every size is known; otherwise by file.
    final sizesKnown = tracks.every((t) => t.size > 0);
    final totalBytes = sizesKnown
        ? tracks.fold<int>(0, (sum, t) => sum + t.size)
        : 0;
    var receivedBytes = 0;
    var result = DownloadResult.failed;
    File? part;
    final keepAlive = DownloadKeepAlive.start(
      title: bookTitle,
      cancelLabel: cancelLabel,
      channelName: channelName,
      onCancel: cancelDownload,
    );
    try {
      // Waiting for Wi-Fi takes up to a few seconds; a cancel ends it.
      _downloadOnWifi = await Future.any([
        keepAlive.onWifi,
        cancel.future.then((_) => false),
      ]);
      if (cancel.isCompleted) throw const _DownloadCanceled();
      _downloadClient = _injectedClient ?? _newClient();
      final dir = Directory(await localDirPath())..createSync(recursive: true);
      for (final (i, t) in tracks.indexed) {
        if (cancel.isCompleted) throw const _DownloadCanceled();
        final target = _localFile(dir.path, t);
        // A finished file only exists after a complete download and rename.
        if (target.existsSync() &&
            (t.size == 0 || target.lengthSync() == t.size)) {
          receivedBytes += t.size;
          continue;
        }
        final response = await _requestDownload(t, cancel.future);
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          throw HttpException('HTTP ${response.statusCode} for ${t.filename}');
        }
        part = File('${target.path}.part');
        // Synchronous writes fail right away when storage is full, instead
        // of after the whole file was fetched.
        final file = part.openSync(mode: FileMode.write);
        final written = Completer<void>();
        void fail(Object e, [StackTrace? s]) {
          if (!written.isCompleted) written.completeError(e, s);
        }

        // Not `await for`: a cancel must end the wait for a stalled chunk.
        unawaited(cancel.future.then((_) => fail(const _DownloadCanceled())));
        // A stalled connection (Wi-Fi drop) must not hang forever.
        final sub = response.stream
            .timeout(const Duration(seconds: 30))
            .listen(
              (chunk) {
                if (written.isCompleted) return;
                try {
                  if (_closed) throw const HttpException('Player closed');
                  file.writeFromSync(chunk);
                } on Object catch (e, s) {
                  fail(e, s);
                  return;
                }
                receivedBytes += chunk.length;
                final progress = totalBytes > 0
                    ? (receivedBytes / totalBytes).clamp(0.0, 1.0)
                    : (i + 1) / tracks.length;
                // Redraw per whole percent, not per network chunk.
                if ((progress * 100).floor() !=
                    ((downloadProgress.value ?? 0) * 100).floor()) {
                  downloadProgress.value = progress;
                  DownloadKeepAlive.progress(progress);
                }
              },
              onError: fail,
              onDone: () {
                if (!written.isCompleted) written.complete();
              },
              cancelOnError: true,
            );
        try {
          await written.future;
        } finally {
          await sub.cancel();
          file.closeSync();
        }
        part.renameSync(target.path);
        part = null;
      }
      result = DownloadResult.done;
    } on _DownloadCanceled {
      result = DownloadResult.canceled;
    } on FileSystemException catch (e) {
      debugPrint('Download failed: $e');
      // ENOSPC is 28 on Linux/Android.
      if (e.osError?.errorCode == 28) result = DownloadResult.noSpace;
    } on Object catch (e) {
      debugPrint('Download failed: $e');
    } finally {
      try {
        if (part?.existsSync() ?? false) part!.deleteSync();
      } on FileSystemException catch (e) {
        debugPrint('Could not remove partial file: $e');
      }
      isDownloading = false;
      _downloadCancel = null;
      _downloadOnWifi = false;
      _closeDownloadClient();
      unawaited(keepAlive.stop());
      if (!_closed) downloadProgress.value = null;
      _notify();
    }
    if (result == DownloadResult.done && !_closed) {
      await _saveSessionMeta();
      await _downloadCover(await localDirPath());
      await reloadSources();
    }
    return result;
  }

  File _coverFile(String dir) => File('$dir/cover.jpg');

  /// Saves the cover next to the audio, so the media notification shows it
  /// offline too. Best effort: a book without a cover is fine.
  Future<void> _downloadCover(String dir) async {
    if (!_hasCover) return;
    final part = File('${_coverFile(dir).path}.part');
    try {
      final response = await _client
          .get(
            Uri.parse('$serverUrl/api/items/$libraryItemId/cover?width=400'),
            headers: _authHeaders,
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return;
      // Renamed only when complete: a broken file would never be replaced.
      await part.writeAsBytes(response.bodyBytes, flush: true);
      await part.rename(_coverFile(dir).path);
    } on Object catch (e) {
      debugPrint('Could not save cover: $e');
      try {
        if (part.existsSync()) part.deleteSync();
      } on FileSystemException {
        // The folder may be gone (download deleted meanwhile).
      }
    }
  }

  Future<void> deleteDownload() async {
    final dir = Directory(await localDirPath());
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    _notify(); // Show "not downloaded" before the slower reload.
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
    // A Play tap meanwhile sets this (see togglePlayPause). Pausing during
    // the reload isn't supported: the stopped player only offers Play.
    // Keeps a Play from a retry after an error that is still reloading.
    _playAfterReload = wasPlaying || (_playAfterReload ?? false);
    var play = wasPlaying;
    try {
      await player.stop();
      // A downloaded book's session plays its files directly; once the
      // download is deleted, an MP4 book needs an HLS stream instead.
      if (episodeId == null &&
          !_streamTracks.any((t) => t.isHls) &&
          tracks.any((t) => !t.directPlayable) &&
          !await isDownloaded()) {
        await _reopenStream(_pendingPosition);
      }
      // Seeks made meanwhile moved the pending position (the stopped
      // player reports it as its position): load there, not at pos.
      await _loadSources(initialTime: _pendingPosition);
    } finally {
      _reloading = false;
      play = _playAfterReload ?? false;
      _playAfterReload = null;
    }
    // stop() reported paused, so a media button pressed meanwhile (headset,
    // notification) was a Play press: play.
    if (player.playing) play = true;
    if (play && !player.playing) unawaited(player.play());
    if (!play && player.playing) unawaited(player.pause());
    _notify();
  }

  /// Starts the download of one file. Retries once when the connection
  /// drops before the response starts, which a reused keep-alive
  /// connection can do.
  ///
  /// When the server can't be reached over the watch's Wi-Fi (e.g. only
  /// through the phone's VPN), retries over the default network.
  Future<http.StreamedResponse> _requestDownload(
    BookTrack t,
    Future<void> canceled,
  ) async {
    for (var attempt = 1; ; attempt++) {
      // Abortable so a timed-out or canceled request releases its
      // connection.
      final abort = Completer<void>();
      final request = http.AbortableRequest(
        'GET',
        Uri.parse('$serverUrl/api/items/$libraryItemId/file/${t.ino}/download'),
        abortTrigger: Future.any([abort.future, canceled]),
      )..headers.addAll(_authHeaders);
      try {
        return await Future.any([
          _downloadClient!.send(request).timeout(const Duration(seconds: 30)),
          canceled.then<http.StreamedResponse>(
            (_) => throw const _DownloadCanceled(),
          ),
        ]);
      } on _DownloadCanceled {
        rethrow;
      } on Object catch (e) {
        if (e is TimeoutException) abort.complete();
        final network = e is TimeoutException || e is http.ClientException;
        if (!network || _closed) rethrow;
        if (e is http.ClientException && attempt == 1) {
          debugPrint('Download request failed, retrying: $e');
          continue;
        }
        if (!_downloadOnWifi) rethrow;
        debugPrint(
          'Download over Wi-Fi failed, trying the default network: $e',
        );
        _downloadOnWifi = false;
        await DownloadKeepAlive.useDefaultNetwork();
        // New connections, over the default network.
        _closeDownloadClient();
        _downloadClient = _injectedClient ?? _newClient();
        attempt = 0;
      }
    }
  }

  /// Replaces the server session with a new one that streams the book as
  /// HLS where needed. The old session is closed at [position] only once
  /// the new one started, so when that fails the old one, still open, is
  /// kept.
  Future<void> _reopenStream(double position) {
    if (isOffline || _closed) return Future.value();
    return _replacingSession(() => _reopenStreamNow(position));
  }

  Future<void> _reopenStreamNow(double position) async {
    if (_closed) return;
    try {
      final response = await _postPlay(directPlay: false);
      if (response.statusCode != 200) return;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final stream =
          (json['audioTracks'] as List? ?? const <Object?>[])
              .cast<Map<String, dynamic>>()
              .map((t) => BookTrack.fromJson(t, const {}))
              .toList()
            ..sort((a, b) => a.startOffset.compareTo(b.startOffset));
      final oldId = sessionId;
      sessionId = json['id'] as String;
      _directPlay = false;
      // Saves the position on the old session. Unreported listening time
      // goes to the new one with the next sync. ABS may have closed the old
      // one already when the new one started; its 404 is fine.
      await _closeSessionAt(oldId, position);
      if (_closed) {
        unawaited(_closeOrphanSession());
        return;
      }
      if (stream.isNotEmpty) _streamTracks = stream;
    } on Object catch (e) {
      debugPrint('Could not start a new stream: $e');
    }
  }

  /// Closes the session on the server (saving the final position) and then
  /// releases the player. Safe to call without awaiting from dispose().
  Future<void> close() {
    if (_closed) return _previousClose;
    _closed = true;
    // Ends a running download now, releasing its service and wake lock.
    cancelDownload();
    // Chained, so a quick close can't let the next player start before a
    // slower earlier close saved its book's position. Errors are swallowed:
    // one failed close must not block the ones after it.
    final previous = _previousClose;
    return _previousClose = Future.wait([previous, _close()]).then<void>(
      (_) {},
      onError: (Object e) => debugPrint('Error closing player: $e'),
    );
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
      // Before the (possibly slow) final sync, so a release can't drop the
      // lock of the next book, which may start meanwhile.
      unawaited(NetworkLock.set(hold: false));
      // Before the book loaded, setupPlayer closes the session itself with
      // the server's position; closing here could send position 0.
      if (isLoaded) {
        await syncOpenSession(close: true, position: position);
      }
    } on Object catch (e) {
      debugPrint('Error closing player: $e');
    } finally {
      // Only this player's registration: a newer player of the same book
      // may already be open.
      final key = _openKey;
      if (key != null) {
        final left = (_openKeys[key] ?? 1) - 1;
        if (left > 0) {
          _openKeys[key] = left;
        } else {
          _openKeys.remove(key);
        }
      }
      _client.close();
      downloadProgress.dispose();
      _sleepTimer?.cancel();
      sleepRemaining.dispose();
      super.dispose();
    }
  }
}

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}
