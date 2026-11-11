import 'package:flutter/services.dart';

/// Why signing in on the phone didn't work.
enum PhoneAuthError {
  /// This watch can't open sign-ins on a phone at all.
  unsupported,

  /// No phone is connected (or it can't do this, e.g. an iPhone).
  phoneUnavailable,

  /// Cancelled on the watch.
  cancelled,

  /// Anything else.
  failed,
}

class PhoneAuthException implements Exception {
  const PhoneAuthException(this.error, [this.detail]);

  final PhoneAuthError error;
  final String? detail;

  @override
  String toString() =>
      'PhoneAuthException($error${detail == null ? '' : ': $detail'})';
}

/// Opens a sign-in in the paired phone's browser and brings the answer back
/// to the watch: Wear OS's RemoteAuthClient, through the `remote_auth`
/// channel (RemoteAuth.kt). The phone needs no app of ours.
class PhoneAuth {
  const PhoneAuth();

  static const _channel = MethodChannel('remote_auth');

  /// The redirect URI the phone's browser must end on: Google's relay back
  /// to this app (`https://wear.googleapis.com/3p_auth/<package>`).
  Future<String> redirectUri() async {
    final uri = await _channel.invokeMethod<String>('redirectUri');
    if (uri == null) throw const PhoneAuthException(PhoneAuthError.failed);
    return uri;
  }

  /// Opens [url] on the phone and waits for the user to finish there.
  /// Returns the URL the browser was redirected to (with the code).
  Future<Uri> authorize(Uri url) async {
    try {
      final response = await _channel.invokeMethod<String>('authorize', {
        'url': url.toString(),
      });
      final parsed = response == null ? null : Uri.tryParse(response);
      if (parsed == null) {
        throw const PhoneAuthException(PhoneAuthError.failed, 'no response');
      }
      return parsed;
    } on PlatformException catch (e) {
      throw PhoneAuthException(switch (e.code) {
        'unsupported' => PhoneAuthError.unsupported,
        'phoneUnavailable' => PhoneAuthError.phoneUnavailable,
        'cancelled' => PhoneAuthError.cancelled,
        _ => PhoneAuthError.failed,
      }, e.message);
    }
  }

  /// Stops waiting for the phone.
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
}
