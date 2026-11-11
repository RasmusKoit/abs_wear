import 'dart:async';

import 'package:abs_wear/login/data/sso/phone_auth.dart';

/// The Wear OS relay URI phone sign-in uses in tests.
const fakeRelayUri = 'https://wear.googleapis.com/3p_auth/dev.koit.abs_wear';

/// Phone sign-in without a phone: [authorize] answers like the relay would
/// after the user signed in on the phone (the code and the login's state),
/// fails with [error], or waits until cancelled.
class FakePhoneAuth extends PhoneAuth {
  FakePhoneAuth({this.code = 'the-code', this.error, this.hang = false});

  final String code;
  final PhoneAuthError? error;
  final bool hang;

  /// The URLs opened on the "phone".
  final opened = <Uri>[];
  int cancels = 0;
  Completer<Uri>? _pending;

  @override
  Future<String> redirectUri() async => fakeRelayUri;

  @override
  Future<Uri> authorize(Uri url) {
    opened.add(url);
    if (error case final e?) return Future.error(PhoneAuthException(e));
    if (hang) return (_pending = Completer<Uri>()).future;
    final state = url.queryParameters['state'];
    return Future.value(
      Uri.parse(
        fakeRelayUri,
      ).replace(queryParameters: {'code': code, 'state': ?state}),
    );
  }

  @override
  Future<void> cancel() async {
    cancels++;
    _pending?.completeError(const PhoneAuthException(PhoneAuthError.cancelled));
    _pending = null;
  }
}
