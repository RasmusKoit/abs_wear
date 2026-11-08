import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a book download going with the screen off: a foreground service
/// with a progress notification (and a cancel action), a wake lock, and the
/// watch's Wi-Fi instead of the phone's Bluetooth proxy. See
/// DownloadService.kt.
abstract final class DownloadKeepAlive {
  static const _channel = MethodChannel('download_keep_alive');
  static VoidCallback? _onCancel;
  static int _percent = -1;

  /// Starts keeping the download alive. [onCancel] runs when the
  /// notification's cancel is tapped. Returns true when the download goes
  /// over Wi-Fi.
  static Future<bool> start({
    required String title,
    required String cancelLabel,
    required String channelName,
    required VoidCallback onCancel,
  }) async {
    _onCancel = onCancel;
    _percent = -1;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cancel') _onCancel?.call();
    });
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

  /// Routes over the default network again (the server isn't reachable over
  /// the watch's Wi-Fi).
  static Future<void> useDefaultNetwork() => _invoke('useDefaultNetwork');

  static Future<void> stop() {
    _onCancel = null;
    return _invoke('stop');
  }

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
