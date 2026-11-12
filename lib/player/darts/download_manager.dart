import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:abs_wear/player/darts/download_keep_alive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Thrown inside a [DownloadJob] when it is canceled.
class _DownloadCanceled implements Exception {
  const _DownloadCanceled();
}

/// The local file of [track] in download folder [dir].
File localTrackFile(String dir, BookTrack track) {
  final dot = track.filename.lastIndexOf('.');
  final ext = dot >= 0 ? track.filename.substring(dot) : '';
  final index = track.index.toString().padLeft(3, '0');
  return File('$dir/${index}_${track.ino}$ext');
}

/// The saved cover in download folder [dir].
File coverFileIn(String dir) => File('$dir/cover.jpg');

/// Saves the item's cover into [dir]; best effort.
Future<void> saveCover({
  required http.Client client,
  required String serverUrl,
  required String token,
  required String itemId,
  required String dir,
}) async {
  final part = File('${coverFileIn(dir).path}.part');
  try {
    final response = await client
        .get(
          Uri.parse('$serverUrl/api/items/$itemId/cover?width=400'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) return;
    // Renamed only when complete: a broken file would never be replaced.
    await part.writeAsBytes(response.bodyBytes, flush: true);
    await part.rename(coverFileIn(dir).path);
  } on Object catch (e) {
    debugPrint('Could not save cover: $e');
    try {
      if (part.existsSync()) part.deleteSync();
    } on FileSystemException {
      // The folder may be gone (download deleted meanwhile).
    }
  }
}

/// One book (or episode) to download, queued in [DownloadManager].
class DownloadJob {
  DownloadJob({
    required this.key,
    required this.dir,
    required this.title,
    required this.serverUrl,
    required this.token,
    required this.libraryItemId,
    required this.tracks,
    required this.hasCover,
    required this.sessionMeta,
    this.episodeId,
    this.cancelLabel = 'Cancel',
    this.channelName = 'Downloads',
    http.Client? client,
  }) : _injectedClient = client;

  /// The download folder's name, which identifies the job.
  final String key;

  /// The download folder.
  final String dir;
  final String title;
  final String serverUrl;
  final String token;
  final String libraryItemId;
  final String? episodeId;
  final List<BookTrack> tracks;
  final bool hasCover;

  /// Saved as session.json once done, so the book plays offline.
  final Map<String, dynamic>? sessionMeta;
  final String cancelLabel;
  final String channelName;

  /// A client passed in (tests): used for every request, never closed.
  final http.Client? _injectedClient;

  /// 0..1 while running, null while queued.
  final ValueNotifier<double?> progress = ValueNotifier(null);

  final Completer<void> _cancel = Completer<void>();
  final Completer<DownloadResult> _result = Completer<DownloadResult>();

  /// Completes when the job ended, however it ended.
  Future<DownloadResult> get result => _result.future;

  bool get isRunning => progress.value != null;

  http.Client? _client;

  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }

  void _closeClient() {
    final client = _client;
    _client = null;
    if (client != null && client != _injectedClient) client.close();
  }

  http.Client _newClient() =>
      _injectedClient ?? IOClient(HttpClient()..idleTimeout = _idleTimeout);

  /// Shorter than the server's keep-alive, like the player's client.
  static const _idleTimeout = Duration(seconds: 3);

  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $token'};

  /// Downloads every file; finished files are kept so a retry resumes.
  Future<DownloadResult> _run(_QueueRun run) async {
    progress.value = 0;
    final sizesKnown = tracks.every((t) => t.size > 0);
    final totalBytes = sizesKnown
        ? tracks.fold<int>(0, (sum, t) => sum + t.size)
        : 0;
    var receivedBytes = 0;
    var result = DownloadResult.failed;
    File? part;
    try {
      // Waiting for Wi-Fi takes up to a few seconds; a cancel ends it.
      await Future.any([run.onWifi, _cancel.future]);
      if (_cancel.isCompleted) throw const _DownloadCanceled();
      _client = _newClient();
      final folder = Directory(dir)..createSync(recursive: true);
      for (final (i, t) in tracks.indexed) {
        if (_cancel.isCompleted) throw const _DownloadCanceled();
        final target = localTrackFile(folder.path, t);
        // A finished file only exists after a complete download and rename.
        if (target.existsSync() &&
            (t.size == 0 || target.lengthSync() == t.size)) {
          receivedBytes += t.size;
          continue;
        }
        final response = await _requestDownload(t, run);
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
        unawaited(_cancel.future.then((_) => fail(const _DownloadCanceled())));
        // A stalled connection (Wi-Fi drop) must not hang forever.
        final sub = response.stream
            .timeout(const Duration(seconds: 30))
            .listen(
              (chunk) {
                if (written.isCompleted) return;
                try {
                  file.writeFromSync(chunk);
                } on Object catch (e, s) {
                  fail(e, s);
                  return;
                }
                receivedBytes += chunk.length;
                final value = totalBytes > 0
                    ? (receivedBytes / totalBytes).clamp(0.0, 1.0)
                    : (i + 1) / tracks.length;
                // Redraw per whole percent, not per network chunk.
                if ((value * 100).floor() !=
                    ((progress.value ?? 0) * 100).floor()) {
                  progress.value = value;
                  DownloadKeepAlive.progress(value);
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
    }
    if (result == DownloadResult.done) {
      await _saveMeta();
      if (hasCover) {
        await saveCover(
          client: _client ?? _newClient(),
          serverUrl: serverUrl,
          token: token,
          itemId: libraryItemId,
          dir: dir,
        );
      }
    }
    _closeClient();
    return result;
  }

  Future<void> _saveMeta() async {
    final meta = sessionMeta;
    if (meta == null) return;
    try {
      if (!Directory(dir).existsSync()) return;
      await File(
        '$dir/session.json',
      ).writeAsString(jsonEncode(meta), flush: true);
    } on Object catch (e) {
      debugPrint('Could not save session details: $e');
    }
  }

  /// Requests one file, retrying once and then over the default network.
  Future<http.StreamedResponse> _requestDownload(
    BookTrack t,
    _QueueRun run,
  ) async {
    for (var attempt = 1; ; attempt++) {
      // Abortable so a timed-out or canceled request releases its
      // connection.
      final abort = Completer<void>();
      final request = http.AbortableRequest(
        'GET',
        Uri.parse('$serverUrl/api/items/$libraryItemId/file/${t.ino}/download'),
        abortTrigger: Future.any([abort.future, _cancel.future]),
      )..headers.addAll(_authHeaders);
      try {
        return await Future.any([
          _client!.send(request).timeout(const Duration(seconds: 30)),
          _cancel.future.then<http.StreamedResponse>(
            (_) => throw const _DownloadCanceled(),
          ),
        ]);
      } on _DownloadCanceled {
        rethrow;
      } on Object catch (e) {
        if (e is TimeoutException) abort.complete();
        final network = e is TimeoutException || e is http.ClientException;
        if (!network) rethrow;
        if (e is http.ClientException && attempt == 1) {
          debugPrint('Download request failed, retrying: $e');
          continue;
        }
        if (!await run.onWifi || run.usedDefault) rethrow;
        debugPrint(
          'Download over Wi-Fi failed, trying the default network: $e',
        );
        run.usedDefault = true;
        await DownloadKeepAlive.useDefaultNetwork();
        // New connections, over the default network.
        _closeClient();
        _client = _newClient();
        attempt = 0;
      }
    }
  }
}

/// Downloads under one keep-alive (service, wake lock, Wi-Fi) until idle.
class _QueueRun {
  _QueueRun(this.keepAlive) : onWifi = keepAlive.onWifi;

  final DownloadKeepAliveHandle keepAlive;

  /// True when the downloads go over the watch's Wi-Fi.
  final Future<bool> onWifi;

  /// Switched to the default network; later jobs stay there.
  bool usedDefault = false;
}

/// Runs book downloads one after another, independent of any page.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();

  static final DownloadManager instance = DownloadManager._();

  /// Queued jobs; the first one runs.
  final List<DownloadJob> _jobs = [];

  final StreamController<(String, DownloadResult)> _finished =
      StreamController.broadcast(sync: true);

  bool _running = false;

  List<DownloadJob> get jobs => List.unmodifiable(_jobs);

  /// The job for the download folder named [key], queued or running.
  DownloadJob? jobFor(String key) {
    for (final job in _jobs) {
      if (job.key == key) return job;
    }
    return null;
  }

  /// Each finished job's key and result.
  Stream<(String, DownloadResult)> get finished => _finished.stream;

  /// Queues [job], or joins the job already queued for its folder.
  Future<DownloadResult> enqueue(DownloadJob job) {
    final existing = jobFor(job.key);
    if (existing != null) return existing.result;
    _jobs.add(job);
    notifyListeners();
    unawaited(_runQueue());
    return job.result;
  }

  /// Cancels the job for [key], queued or running.
  void cancel(String key) {
    final job = jobFor(key);
    if (job == null) return;
    if (job.isRunning) {
      job.cancel();
    } else {
      _finish(job, DownloadResult.canceled);
    }
  }

  /// Cancels every job; completes once they all ended.
  Future<void> cancelAll() {
    final all = List.of(_jobs);
    for (final job in all) {
      cancel(job.key);
    }
    return Future.wait([for (final job in all) job.result]);
  }

  void _finish(DownloadJob job, DownloadResult result) {
    if (!_jobs.remove(job)) return;
    job.progress.value = null;
    if (!job._result.isCompleted) job._result.complete(result);
    notifyListeners();
    _finished.add((job.key, result));
  }

  Future<void> _runQueue() async {
    if (_running) return;
    _running = true;
    _QueueRun? run;
    try {
      while (_jobs.isNotEmpty) {
        final job = _jobs.first;
        if (run == null) {
          run = _QueueRun(
            DownloadKeepAlive.start(
              title: job.title,
              cancelLabel: job.cancelLabel,
              channelName: job.channelName,
              // The notification's cancel stops the whole queue.
              onCancel: () => unawaited(cancelAll()),
            ),
          );
        } else {
          DownloadKeepAlive.retitle(job.title);
        }
        final running = job._run(run);
        notifyListeners();
        _finish(job, await running);
      }
    } finally {
      _running = false;
      unawaited(run?.keepAlive.stop());
    }
  }
}
