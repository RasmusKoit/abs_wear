import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the watch's Wi-Fi up while a streamed book plays (Wear OS turns
/// Wi-Fi off soon after the screen goes off, which stalls streaming once
/// the buffer runs out). See NetworkLock.kt.
abstract final class NetworkLock {
  static const _channel = MethodChannel('network_lock');
  static bool _held = false;

  /// Holds the network while [hold] is true; cheap to call repeatedly.
  static Future<void> set({required bool hold}) async {
    if (hold == _held) return;
    _held = hold;
    try {
      final ok = await _channel.invokeMethod<bool>(
        hold ? 'acquire' : 'release',
      );
      // Not held after all: let the next call try again.
      if (hold && ok == false && _held) _held = false;
    } on MissingPluginException {
      // Tests, or the activity's channel isn't registered yet.
      if (_held == hold) _held = !hold;
    } on PlatformException catch (e) {
      debugPrint('Network lock: $e');
      if (_held == hold) _held = !hold;
    }
  }
}
