import 'dart:async';

import 'package:flutter/services.dart';

/// Bluetooth audio outputs; without the platform side, counted as connected.
class AudioOutput {
  AudioOutput._();

  static const _channel = MethodChannel('audio_output');

  static StreamController<bool>? _changes;

  /// Whether A2DP, LE Audio or a hearing aid is connected.
  static Future<bool> hasHeadphones() async {
    try {
      return await _channel.invokeMethod<bool>('hasHeadphones') ?? true;
    } on Exception {
      return true;
    }
  }

  /// Opens the system Bluetooth picker; false if it could not be opened.
  static Future<bool> openBluetoothSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openBluetoothSettings') ??
          false;
    } on Exception {
      return false;
    }
  }

  /// Headphone connection changes, watched while listened to.
  static Stream<bool> get changes {
    return (_changes ??= StreamController<bool>.broadcast(
      onListen: () {
        _channel.setMethodCallHandler((call) async {
          if (call.method == 'changed' && call.arguments is bool) {
            _changes?.add(call.arguments as bool);
          }
        });
        unawaited(_invoke('watch'));
      },
      onCancel: () {
        _channel.setMethodCallHandler(null);
        unawaited(_invoke('unwatch'));
      },
    )).stream;
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on Exception {
      // No platform side.
    }
  }
}
