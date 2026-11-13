import 'dart:async';

import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// App-wide owner of the playing book's controller; pages attach and detach.
class NowPlaying extends ChangeNotifier {
  NowPlaying._();

  static final NowPlaying instance = NowPlaying._();

  /// Makes controllers; tests swap it for one with a fake client.
  @visibleForTesting
  AudioPlayerController Function() create = AudioPlayerController.new;

  AudioPlayerController? _controller;
  String? _key;
  Future<bool> _ready = Future.value(false);
  Timer? _syncTimer;

  bool _notifyQueued = false;

  /// Opened from a page's initState: notify after the frame, not mid-build.
  @override
  void notifyListeners() {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      super.notifyListeners();
      return;
    }
    if (_notifyQueued) return;
    _notifyQueued = true;
    scheduler.addPostFrameCallback((_) {
      _notifyQueued = false;
      super.notifyListeners();
    });
  }

  /// The open book's controller, while loading or loaded.
  AudioPlayerController? get controller => _controller;

  /// Opens a book, attaching when it is already open; replaces another.
  ({AudioPlayerController controller, Future<bool> ready, bool created}) open({
    required String libraryItemId,
    required String serverUrl,
    required String token,
    required String user,
    String? episodeId,
  }) {
    // Not the token: a refreshed one still means the same login (see logout).
    final key = [serverUrl, user, libraryItemId, episodeId].join('|');
    final current = _controller;
    if (current != null && current.isOpen && _key == key) {
      return (controller: current, ready: _ready, created: false);
    }
    unawaited(_release());
    final controller = _controller = create();
    _key = key;
    _ready = _setup(
      controller,
      libraryItemId: libraryItemId,
      serverUrl: serverUrl,
      token: token,
      user: user,
      episodeId: episodeId,
    );
    notifyListeners();
    return (controller: controller, ready: _ready, created: true);
  }

  Future<bool> _setup(
    AudioPlayerController controller, {
    required String libraryItemId,
    required String serverUrl,
    required String token,
    required String user,
    String? episodeId,
  }) async {
    final ok = await controller.setupPlayer(
      libraryItemId,
      serverUrl,
      token,
      userName: user,
      episodeId: episodeId,
    );
    // Replaced or stopped meanwhile: that already closed it.
    if (_controller != controller) return false;
    if (!ok) {
      unawaited(_release());
      notifyListeners();
      return false;
    }
    // Saves each minute; posts every 10th while playing; reconnects offline.
    _syncTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(controller.periodicSync()),
    );
    notifyListeners();
    return true;
  }

  /// Closes the open book (e.g. on logout), saving its final position.
  Future<void> stop() {
    if (_controller == null) return AudioPlayerController.lastClose;
    final closing = _release();
    notifyListeners();
    return closing;
  }

  Future<void> _release() {
    _syncTimer?.cancel();
    _syncTimer = null;
    final controller = _controller;
    _controller = null;
    _key = null;
    _ready = Future.value(false);
    // Chained in close(): the next book's session starts only after this.
    return controller?.close() ?? Future.value();
  }

  /// Completes once the open and last closed books saved their progress.
  static Future<void> settled() async {
    final controller = instance._controller;
    if (controller != null && controller.isLoaded) {
      // The library shows server progress: post now, not on the 10th tick.
      await controller
          .periodicSync(post: true)
          .timeout(const Duration(seconds: 25), onTimeout: () {});
    }
    await AudioPlayerController.lastClose;
  }
}
