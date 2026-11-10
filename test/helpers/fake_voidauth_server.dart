import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fake_sso_servers.dart';

/// VoidAuth 1.19's app page (`/login`, `/mfa`, `/consent/<uid>` all serve
/// it), trimmed: the Angular shell with its base href, title, logo meta tag
/// and generated theme.
const voidAuthPage = '''
<!doctype html>
<html lang="en" data-beasties-container="">
  <head><meta http-equiv="Content-Security-Policy" content="script-src 'strict-dynamic' https: 'unsafe-inline';object-src 'none';base-uri 'self';">
    <meta charset="utf-8">
    <title>VoidAuth</title>
    <base href="/"/>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="logoUri" content="logo.svg">

    <link rel="icon" href="favicon.svg" sizes="any" type="image/svg+xml">
    <link rel="apple-touch-icon" href="apple-touch-icon.png">

    <link rel="stylesheet" href="material-icons.css">
    <link rel="stylesheet" href="generated-mat-theme.css">
    <link rel="stylesheet" href="custom.css">
  <link rel="stylesheet" href="styles-RR3DDK4W.css" media="print" data-beasties-media="all"></head>
  <body>
    <app-root></app-root>
  <script>(() => {
  const scripts = [['polyfills-5CFQRCPP.js', "module", false, false, null, null],['main-G3VRUNAV.js', "module", false, false, null, null]];
})();
</script></body>
</html>
''';

/// What VoidAuth sends the user to after the password.
enum VoidAuthNext {
  /// Straight back to the server (consent given before).
  done,

  /// The consent page.
  consent,

  /// The MFA page, for a TOTP code.
  totp,

  /// The MFA page, for a user with only a passkey.
  passkey,

  /// "Check your email" (email verification on, address not verified).
  verifyEmail,

  /// The account is waiting for an admin's approval.
  approval,

  /// The account has expired.
  userExpired,

  /// The user is not in a group allowed to use the app.
  forbidden,

  /// The MFA page for a user who must set up a second factor and has none.
  mfaSetup,
}

/// A fake Audiobookshelf + VoidAuth pair answering like the real ones (the
/// requests and responses are trimmed copies of VoidAuth 1.19's, recorded
/// against the dev box test stack).
class FakeVoidAuthServers extends FakeServers {
  FakeVoidAuthServers({
    this.next = VoidAuthNext.consent,
    String base = '/',
    this.fail = const {},
    this.meBody,
    this.detailBody,
  }) : _base = base,
       super(
         idpAuthorizeUrl:
             '$fakeIdpUrl${base}oidc/auth?client_id=abs&scope=openid%20profile'
             '%20email&response_type=code&redirect_uri=http%3A%2F%2Fabs.test'
             '%2Fauth%2Fopenid%2Fmobile-redirect',
       );

  final VoidAuthNext next;
  final String _base;

  /// Error statuses VoidAuth answers with instead, by API call: `login`
  /// (419: the login took too long), `totp` (423: too many wrong codes),
  /// `confirm` (419 or 400 from the consent confirm).
  final Map<String, int> fail;

  /// Raw bodies for `api/user/me` and the consent detail, in place of the
  /// recorded JSON (a proxy's HTML page, another VoidAuth version, ...).
  final String? meBody;
  final String? detailBody;

  http.Response? _failure(String call) {
    final status = fail[call];
    if (status == null) return null;
    return http.Response(
      'Error',
      status,
      headers: {'content-type': 'text/plain; charset=utf-8'},
    );
  }

  /// Interaction steps left after the password: 'totp', 'consent'.
  final _pending = <String>[];
  bool _loggedIn = false;
  int _uid = 0;
  bool consented = false;

  String get _uidNow => 'uid$_uid';

  static const _cookieAttrs =
      'expires=Tue, 10 Nov 2026 22:40:16 GMT; samesite=lax; httponly';

  /// Starts an interaction (node-oidc-provider's interaction cookie).
  http.Response _toInteraction() {
    _uid++;
    return http.Response(
      'Redirecting to ${_base}api/interaction.',
      303,
      headers: {
        'location': '${_base}api/interaction',
        'content-type': 'text/html; charset=utf-8',
        'set-cookie':
            'x-voidauth-interaction=$_uidNow; path=${_base}api/interaction; '
            '$_cookieAttrs,x-voidauth-resume=$_uidNow; '
            'path=${_base}oidc/auth/$_uidNow; $_cookieAttrs',
      },
    );
  }

  http.Response _page(String route) {
    final to = '$fakeIdpUrl$_base$route';
    return http.Response(
      '<!DOCTYPE html><head><title>Found</title></head><body><p>Found. '
      'Redirecting to $to</p></body>',
      302,
      headers: {'location': to},
    );
  }

  http.Response _redirectLocation() => http.Response(
    jsonEncode({
      'success': true,
      'location': '$fakeIdpUrl${_base}oidc/auth/$_uidNow',
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static final _unauthorized = http.Response(
    'Unauthorized',
    401,
    headers: {'content-type': 'text/plain; charset=utf-8'},
  );

  @override
  Future<http.Response> handle(http.Request r) async {
    final url = r.url.toString();
    if (!url.startsWith(fakeIdpUrl)) return await super.handle(r);
    final path = r.url.path;
    final interaction = (r.headers['Cookie'] ?? '').contains(
      'x-voidauth-interaction=$_uidNow',
    );
    if (path == '${_base}oidc/auth') return _toInteraction();
    if (path.startsWith('${_base}oidc/auth/')) {
      expect(path, endsWith(_uidNow));
      if (_pending.isEmpty) {
        return http.Response(
          '',
          303,
          headers: {
            'location':
                '$fakeAbsUrl/auth/openid/mobile-redirect?code=$code'
                '&state=$state&iss=http%3A%2F%2Fidp.test%2Foidc',
          },
        );
      }
      return _toInteraction();
    }
    if (path == '${_base}api/interaction') {
      expect(interaction, isTrue);
      if (!_loggedIn) return _page('login');
      return switch (_pending.first) {
        'totp' => _page('mfa'),
        'verify' => _page('verification_email_sent?sent=false'),
        'approval' => _page('approval_required'),
        'expired' => _page('user_expired'),
        'forbidden' => _page('forbidden'),
        _ => _page('consent/$_uidNow'),
      };
    }
    if (r.method == 'GET' &&
        (path == '${_base}login' ||
            path == '${_base}mfa' ||
            path == '${_base}approval_required' ||
            path == '${_base}user_expired' ||
            path == '${_base}forbidden' ||
            path == '${_base}verification_email_sent' ||
            path.startsWith('${_base}consent/'))) {
      final page = voidAuthPage.replaceFirst(
        '<base href="/"/>',
        '<base href="$_base"/>',
      );
      return http.Response(page, 200);
    }
    if (path == '${_base}api/interaction/login') {
      expect(r.method, 'POST');
      expect(interaction, isTrue);
      final failure = _failure('login');
      if (failure != null) return failure;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (body['input'] != 'wear' || body['password'] != 'secret') {
        return _unauthorized;
      }
      _loggedIn = true;
      _pending.addAll(switch (next) {
        VoidAuthNext.done => [],
        VoidAuthNext.consent => ['consent'],
        VoidAuthNext.totp => ['totp', 'consent'],
        VoidAuthNext.passkey => ['totp'],
        VoidAuthNext.verifyEmail => ['verify'],
        VoidAuthNext.approval => ['approval'],
        VoidAuthNext.userExpired => ['expired'],
        VoidAuthNext.forbidden => ['forbidden'],
        VoidAuthNext.mfaSetup => ['totp'],
      });
      return _redirectLocation();
    }
    if (path == '${_base}api/user/me') {
      if (meBody != null) return http.Response(meBody!, 200);
      final totp =
          next != VoidAuthNext.passkey && next != VoidAuthNext.mfaSetup;
      final passkeys = next == VoidAuthNext.passkey;
      return this.json({
        'id': 'c740670f-1ce9-428b-a4db-3232e0983569',
        'isAdmin': false,
        'emailVerified': false,
        'mfaRequired': true,
        'hasTotp': totp,
        'hasPasskeys': passkeys,
        'hasVerifyPasskeys': passkeys,
        'expiresAt': null,
        'approved': true,
        'skipPasskeyPrompt': false,
        'amr': ['pwd'],
        'canLogin': false,
        'isPrivilegedForTotpCreate': false,
        'isPrivilegedForTotpValidate': true,
        'isPrivilegedForPasskeyCreate': false,
        'isPrivilegedForEmail': false,
        'hasEmail': false,
      });
    }
    if (path == '${_base}api/interaction/totp') {
      expect(r.method, 'POST');
      final failure = _failure('totp');
      if (failure != null) return failure;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (body['token'] != '123456') return _unauthorized;
      _pending.remove('totp');
      return _redirectLocation();
    }
    if (path == '${_base}api/interaction/$_uidNow/detail') {
      if (detailBody != null) return http.Response(detailBody!, 200);
      return this.json({
        'uid': _uidNow,
        'clientId': 'abs',
        'clientName': 'Audiobookshelf',
        'redirectUri': '$fakeAbsUrl/auth/openid/mobile-redirect',
        'scopes': ['openid', 'profile', 'email'],
      });
    }
    if (path == '${_base}api/interaction/$_uidNow/confirm/') {
      expect(r.method, 'POST');
      expect(interaction, isTrue);
      final failure = _failure('confirm');
      if (failure != null) return failure;
      consented = true;
      _pending.remove('consent');
      return http.Response(
        '',
        302,
        headers: {'location': '$fakeIdpUrl${_base}oidc/auth/$_uidNow'},
      );
    }
    return http.Response('Not Found', 404);
  }
}
