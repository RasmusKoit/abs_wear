import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a book download going with the screen off: a foreground service
/// with a progress notification (and a cancel action), a wake lock, and the
/// watch's Wi-Fi instead of the phone's Bluetooth proxy. See
/// DownloadService.kt.
///
/// The native side is global; the latest [start] owns it, so a download
/// queue that ends late can't stop a newer one.
abstract final class DownloadKeepAlive {
  static const _channel = MethodChannel('download_keep_alive');
  static DownloadKeepAliveHandle? _owner;
  static int _percent = -1;

  /// Starts keeping a download alive. [onCancel] runs when the
  /// notification's cancel is tapped.
  static DownloadKeepAliveHandle start({
    required String title,
    required String cancelLabel,
    required String channelName,
    required VoidCallback onCancel,
  }) {
    _percent = -1;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cancel') _owner?._onCancel();
    });
    final handle = DownloadKeepAliveHandle._(onCancel);
    _owner = handle;
    handle.onWifi = _start(title, cancelLabel, channelName);
    return handle;
  }

  static Future<bool> _start(
    String title,
    String cancelLabel,
    String channelName,
  ) async {
    try {
      return await _channel.invokeMethod<bool>('start', {
            'title': title,
            'cancel': cancelLabel,
            'channel': channelName,
          }) ??
          false;
    } on MissingPluginException {
      return false; // Tests.
    } on PlatformException catch (e) {
      debugPrint('Download keep-alive: $e');
      return false;
    }
  }

  /// Shows [progress] (0..1) in the notification; cheap to call often.
  static void progress(double progress) {
    final percent = (progress * 100).floor();
    if (percent == _percent) return;
    _percent = percent;
    unawaited(_invoke('progress', {'percent': percent}));
  }

  /// Shows [title] (the next queued book) in the notification.
  static void retitle(String title) {
    _percent = -1;
    unawaited(_invoke('title', {'title': title}));
  }

  /// Routes over the default network again (the server isn't reachable over
  /// the watch's Wi-Fi).
  static Future<void> useDefaultNetwork() => _invoke('useDefaultNetwork');

  static Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Tests.
    } on PlatformException catch (e) {
      debugPrint('Download keep-alive: $e');
    }
  }
}

/// One download's hold on [DownloadKeepAlive].
class DownloadKeepAliveHandle {
  DownloadKeepAliveHandle._(this._onCancel);

  final VoidCallback _onCancel;

  /// Completes with true when the download goes over the watch's Wi-Fi.
  late final Future<bool> onWifi;

  /// Releases the service, wake lock and Wi-Fi, unless a newer download
  /// owns them by now.
  Future<void> stop() {
    if (DownloadKeepAlive._owner != this) return Future.value();
    DownloadKeepAlive._owner = null;
    return DownloadKeepAlive._invoke('stop');
  }
}
