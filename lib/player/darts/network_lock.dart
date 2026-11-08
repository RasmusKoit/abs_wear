import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a fast network up while a streamed book plays (Wear OS turns
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
      await _channel.invokeMethod<void>(hold ? 'acquire' : 'release');
    } on MissingPluginException {
      // Tests and platforms without the native side.
    } on PlatformException catch (e) {
      debugPrint('Network lock: $e');
    }
  }
}
