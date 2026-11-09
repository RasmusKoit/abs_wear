import 'package:flutter/services.dart';

const _channel = MethodChannel('toast');

/// Shows [message] in a system toast (handled by MainActivity). Fails
/// silently: a missing toast must never break the caller.
Future<void> showToast(String message, {bool long = false}) async {
  try {
    await _channel.invokeMethod<void>('show', {
      'message': message,
      'long': long,
    });
  } on Exception {
    // No platform side (tests) or the toast could not be shown.
  }
}
