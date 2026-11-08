// audio_player.dart
// Audio player controller: playback sessions, multi-file books, chapter
// navigation, progress sync and offline downloads.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/player/darts/network_lock.dart';
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

enum DownloadResult { done, noSpace, failed }

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

  /// Local progress keys of books open in a player; [pushLocalProgress]
  /// leaves those to the player.
  static final Set<String> _openKeys = {};

  /// The running [pushLocalProgress], so runs don't overlap and a player
  /// starts only after a push of its book finished.
  static Future<void> _pushing = Future.value();

  final http.Client _client;
  final AudioPlayer player = AudioPlayer(
    // The default 50 s buffer runs dry within a minute when the network
    // drops (e.g. the watch switches from Wi-Fi to Bluetooth with the
    // screen off). Audiobooks are low bitrate: buffer 10 min, at most 16 MB.
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(minutes: 10),
        maxBufferDuration: Duration(minutes: 10),
        targetBufferBytes: 16 * 1024 * 1024,
      ),
    ),
  );

  /// The loaded audio is streamed from the server (not downloaded).
  bool _streaming = false;

  List<BookTrack> tracks = [];
  List<BookChapter> chapters = [];
  String sessionId = '';
  String bookTitle = '';
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
    String authToken, {
    String userName = '',
    String? episodeId,
  }) async {
    libraryItemId = libItemId;
    this.episodeId = episodeId;
    serverUrl = srvUrl;
    token = authToken;
    user = userName;
    _openKeys.add(_localKey);

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
      final response = await _client
          .post(
            Uri.parse(
              '$serverUrl/api/items/$libraryItemId/play'
              '${episodeId == null ? '' : '/$episodeId'}',
            ),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: await _deviceInfoBody(),
          )
          .timeout(Duration(seconds: canPlayOffline ? 5 : 20));
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
        if (tracks.isEmpty) return false;
        await _resumeLocalProgress();
        await _loadSources(initialTime: _pendingPosition);
        if (await isDownloaded()) unawaited(_saveSessionMeta());
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
          if (_openKeys.contains(key)) continue;
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
          if (_openKeys.contains(key) ||
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
    final libItem = json['libraryItem'];
    final files =
        libItem is Map<String, dynamic> && libItem['libraryFiles'] is List
        ? (libItem['libraryFiles'] as List).cast<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];
    final mediaMeta = json['mediaMetadata'];
    _sessionMeta = {
      'duration': json['duration'],
      'currentTime': json['currentTime'],
      'displayTitle': json['displayTitle'],
      'mediaMetadata': {
        'title': mediaMeta is Map<String, dynamic> ? mediaMeta['title'] : null,
      },
      'audioTracks': json['audioTracks'],
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

  /// (Re)loads all tracks into the player, preferring local files, and
  /// positions it at [initialTime] seconds into the book.
  Future<void> _loadSources({required double initialTime}) async {
    final local = await isDownloaded();
    _streaming = !local;
    final dir = await localDirPath();
    final sources = [
      for (final t in tracks)
        AudioSource.uri(
          local
              ? Uri.file(_localFile(dir, t).path)
              : Uri.parse('$serverUrl${t.contentUrl}'),
          headers: local ? null : _authHeaders,
          tag: MediaItem(
            id: '$_mediaPath/${t.index}',
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
        synced = true;
        _lastSyncedTime = current;
        _reportedListening = _listenClock.elapsed;
        _carriedListening = Duration.zero;
      }
    } on Object catch (e) {
      debugPrint('Error syncing session: $e');
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

  /// Downloads every audio file of the book, streaming each to disk and
  /// reporting progress through [downloadProgress]. Finished files are kept
  /// on failure, so a retry resumes with the next file.
  Future<DownloadResult> downloadBook() async {
    if (isDownloading || tracks.isEmpty) return DownloadResult.failed;
    isDownloading = true;
    downloadProgress.value = 0;
    _notify();

    final dir = Directory(await localDirPath());
    // Byte progress only when every size is known; otherwise by file.
    final sizesKnown = tracks.every((t) => t.size > 0);
    final totalBytes = sizesKnown
        ? tracks.fold<int>(0, (sum, t) => sum + t.size)
        : 0;
    var receivedBytes = 0;
    var result = DownloadResult.failed;
    File? part;
    try {
      dir.createSync(recursive: true);
      for (final (i, t) in tracks.indexed) {
        final target = _localFile(dir.path, t);
        // A finished file only exists after a complete download and rename.
        if (target.existsSync() &&
            (t.size == 0 || target.lengthSync() == t.size)) {
          receivedBytes += t.size;
          continue;
        }
        // Abortable so a timed-out request releases its connection.
        final abort = Completer<void>();
        final request = http.AbortableRequest(
          'GET',
          Uri.parse(
            '$serverUrl/api/items/$libraryItemId/file/${t.ino}/download',
          ),
          abortTrigger: abort.future,
        )..headers.addAll(_authHeaders);
        final http.StreamedResponse response;
        try {
          response = await _client
              .send(request)
              .timeout(const Duration(seconds: 30));
        } on TimeoutException {
          abort.complete();
          rethrow;
        }
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          throw HttpException('HTTP ${response.statusCode} for ${t.filename}');
        }
        part = File('${target.path}.part');
        // Synchronous writes fail right away when storage is full, instead
        // of after the whole file was fetched.
        final file = part.openSync(mode: FileMode.write);
        try {
          // A stalled connection (Wi-Fi drop) must not hang forever.
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 30),
          )) {
            if (_closed) throw const HttpException('Player closed');
            file.writeFromSync(chunk);
            receivedBytes += chunk.length;
            final progress = totalBytes > 0
                ? (receivedBytes / totalBytes).clamp(0.0, 1.0)
                : (i + 1) / tracks.length;
            // Redraw per whole percent, not per network chunk.
            if ((progress * 100).floor() !=
                ((downloadProgress.value ?? 0) * 100).floor()) {
              downloadProgress.value = progress;
            }
          }
        } finally {
          file.closeSync();
        }
        part.renameSync(target.path);
        part = null;
      }
      result = DownloadResult.done;
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
      if (!_closed) downloadProgress.value = null;
      _notify();
    }
    if (result == DownloadResult.done && !_closed) {
      await _saveSessionMeta();
      await reloadSources();
    }
    return result;
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
      _openKeys.remove(_localKey);
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
