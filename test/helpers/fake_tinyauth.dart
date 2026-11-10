import 'dart:convert';

import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_sso_servers.dart' show fakeAbsUrl;

const fakeTinyauthUrl = 'https://tinyauth.test';
const _mobileRedirect = '$fakeAbsUrl/auth/openid/mobile-redirect';

/// tinyauth v5.2.0's web interface, as served at `/oidc/authorize` and
/// `/error` (every screen is this one page).
const tinyauthHtml = '''
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <link rel="icon" type="image/png" href="/favicon-96x96.png" sizes="96x96" />
    <meta name="apple-mobile-web-app-title" content="Tinyauth" />
    <meta name="robots" content="nofollow, noindex" />
    <title>Tinyauth</title>
    <script type="module" crossorigin src="/assets/index-DkKRG-PS.js"></script>
  </head>
  <body>
    <div id="root"></div>
  </body>
</html>
''';

/// A fake Audiobookshelf + tinyauth pair. tinyauth's answers are trimmed
/// copies of tinyauth v5.2.0's (recorded against the container in
/// tool/abs_test_server/idps/tinyauth), with switches for the other cases.
class FakeTinyauth {
  FakeTinyauth({
    this.totp = false,
    this.consentRemembered = false,
    this.providers = const [
      {'name': 'Local', 'id': 'local', 'oauth': false},
    ],
    this.autoRedirect = '',
    this.lockedOut = false,
    this.totpLockedOut = false,
    this.ticketExpired = false,
    this.authorizeError,
  });

  /// The user has a TOTP secret.
  final bool totp;

  /// The user allowed the app before (skip-consent says so).
  final bool consentRemembered;
  final List<Map<String, Object>> providers;
  final String autoRedirect;

  /// Too many wrong answers: tinyauth's lock.
  final bool lockedOut;

  /// Too many wrong TOTP codes: tinyauth's lock on the code step.
  final bool totpLockedOut;

  /// authorize-complete no longer knows the ticket.
  final bool ticketExpired;

  /// tinyauth refuses the authorize request (e.g. an untrusted redirect URI)
  /// with this message on its error page.
  final String? authorizeError;

  static const ticket = 'yW3XgV4RD8_uvy9Adsmti7Gmrp7S1qeF';
  static const code = '_mRiJ1Pj_LcllIqUn8md17V2CyYp42o6';
  static const session = 'tinyauth-session-dbad9be8';

  String? state;
  final requests = <http.Request>[];

  late final client = MockClient((request) async {
    requests.add(request);
    expect(request.followRedirects, isFalse);
    return await handle(request);
  });

  http.Response redirect(String to, {Map<String, String> headers = const {}}) =>
      http.Response('', 302, headers: {'location': to, ...headers});

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response html(String body) => http.Response(
    body,
    200,
    headers: {'content-type': 'text/html; charset=utf-8'},
  );

  http.Response unauthorized() =>
      json({'message': 'Unauthorized', 'status': 401}, 401);

  /// Sets tinyauth's session cookie: "pending" is a login waiting for its
  /// TOTP code, "user" a logged-in user.
  http.Response loggedIn(String value) {
    return http.Response(
      jsonEncode(
        value == 'pending'
            ? {'message': 'TOTP required', 'status': 200, 'totpPending': true}
            : {'message': 'Login successful', 'status': 200},
      ),
      200,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'set-cookie':
            '$session=$value-id; Path=/; Domain=test; Max-Age=86399; '
            'HttpOnly; SameSite=Lax',
      },
    );
  }

  Future<http.Response> handle(http.Request r) async {
    final url = r.url.toString();
    final path = r.url.path;
    final q = r.url.queryParameters;
    if (url.startsWith(fakeAbsUrl)) {
      switch (path) {
        case '/status':
          return json({
            'serverVersion': '2.37.2',
            'authMethods': ['local', 'openid'],
          });
        case '/auth/openid':
          state = q['state'];
          return redirect(
            '$fakeTinyauthUrl/authorize?client_id=abs'
            '&scope=openid%20profile%20email&response_type=code'
            '&redirect_uri=${Uri.encodeComponent(_mobileRedirect)}'
            '&state=$state&code_challenge=c&code_challenge_method=S256',
            headers: {'set-cookie': 'connect.sid=s%3Aabc; Path=/; HttpOnly'},
          );
        case '/auth/openid/mobile-redirect':
          return redirect('$ssoRedirectUri?code=${q['code']}&state=$state');
        case '/auth/openid/callback':
          expect(q['code'], code);
          return json({
            'user': {'username': 'wear', 'token': 'legacy-token'},
            'userDefaultLibraryId': 'lib1',
          });
      }
    }
    if (!url.startsWith(fakeTinyauthUrl)) {
      return http.Response('not found: $url', 404);
    }
    final cookie = r.headers['Cookie'] ?? '';
    final pending = cookie.contains('$session=pending-id');
    final user = cookie.contains('$session=user-id');
    final body = r.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
    switch ((r.method, path)) {
      case ('GET', '/authorize'):
        if (authorizeError != null) {
          return redirect(
            '$fakeTinyauthUrl/error?error='
            '${Uri.encodeQueryComponent(authorizeError!)}',
          );
        }
        return redirect(
          '$fakeTinyauthUrl/oidc/authorize?login_for=oidc'
          '&oidc_name=Audiobookshelf&oidc_scope=openid+profile+email'
          '&oidc_ticket=$ticket',
        );
      case ('GET', '/oidc/authorize' || '/error'):
        return html(tinyauthHtml);
      case ('GET', '/api/context/app'):
        return json({
          'status': 200,
          'message': 'Success',
          'auth': {'providers': providers},
          'oauth': {'autoRedirect': autoRedirect},
          'ui': {'title': 'Tinyauth'},
          'app': {
            'appUrl': fakeTinyauthUrl,
            'cookieDomain': 'test',
            'subdomainsEnabled': true,
          },
        });
      case ('POST', '/api/user/login'):
        if (lockedOut) {
          return json({
            'status': 429,
            'message':
                'Too many failed login attempts. Try again in 299 '
                'seconds',
          }, 429);
        }
        if (body['username'] != 'wear' || body['password'] != 'secret') {
          return unauthorized();
        }
        return loggedIn(totp ? 'pending' : 'user');
      case ('POST', '/api/user/totp'):
        if (!pending) return unauthorized();
        if (totpLockedOut) {
          return json({
            'status': 429,
            'message':
                'Too many failed TOTP attempts. Try again in 299 seconds',
          }, 429);
        }
        if (body['code'] != '123456') return unauthorized();
        return loggedIn('user');
      case ('GET', '/api/oidc/skip-consent'):
        if (!user) {
          return json({'status': 401, 'message': 'User not logged in'}, 401);
        }
        expect(q['oidc_ticket'], ticket);
        return json({'skipConsent': consentRemembered});
      case ('POST', '/api/oidc/authorize-complete'):
        expect(user, isTrue);
        expect(body['ticket'], ticket);
        if (ticketExpired) {
          return json({
            'redirect_uri':
                '$fakeTinyauthUrl/error?error=The+authorization+request+has'
                '+expired+or+is+invalid',
            'status': 200,
          });
        }
        return json({
          'redirect_uri':
              '$fakeAbsUrl/auth/openid/mobile-redirect?code=$code'
              '&state=$state',
          'status': 200,
        });
    }
    return http.Response('404 page not found', 404);
  }

  /// Whether tinyauth's login endpoint got [password].
  bool sentPassword(String password) => requests.any(
    (r) => r.url.path == '/api/user/login' && r.body.contains(password),
  );
}
