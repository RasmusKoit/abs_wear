import 'dart:convert';

import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const fakeAbsUrl = 'http://abs.test';
const fakeIdpUrl = 'http://idp.test';

/// A fake Audiobookshelf + Authentik pair answering like the real ones (the
/// challenges are trimmed copies of Authentik 2026.8's), with switches for
/// the failure cases.
class FakeServers {
  FakeServers({
    this.openid = true,
    this.password = true,
    this.passwordOnFirstPage = false,
    this.startStatus = 302,
    this.webauthnOnly = false,
    this.otp = false,
    this.callbackError,
    this.code = 'the-code',
    this.badState = false,
    this.idpPagePath = '/if/flow/default-authentication-flow/',
    this.authorizePath = '/application/o/authorize/',
    this.idpAuthorizeUrl,
    this.buttonText,
    this.autoLaunch = false,
  });

  final bool openid;

  /// The admin's label for the SSO button (`authOpenIDButtonText`), sent in
  /// `/status` when set.
  final String? buttonText;

  /// The admin's "auto launch" setting (`authOpenIDAutoLaunch`), sent in
  /// `/status` when set.
  final bool autoLaunch;

  /// The server also offers password login.
  final bool password;

  /// Authentik asks for the username and password on one page.
  final bool passwordOnFirstPage;
  final int startStatus;
  final bool webauthnOnly;
  final bool otp;
  final String? callbackError;
  final String code;
  final bool badState;
  final String idpPagePath;

  /// Where the server sends the user to log in at the identity provider.
  final String authorizePath;

  /// A whole authorize URL instead (another host or query); overrides
  /// [authorizePath].
  final String? idpAuthorizeUrl;

  String? state;
  String? challenge;
  final requests = <http.Request>[];
  bool _passwordOk = false;
  String _flow = 'auth';
  Map<String, dynamic>? _current;

  late final client = MockClient((request) async {
    requests.add(request);
    // The SSO flow handles redirects itself (the app's other calls don't).
    if (request.url.path.startsWith('/auth/') ||
        request.url.toString().startsWith(fakeIdpUrl)) {
      expect(request.followRedirects, isFalse);
    }
    return await handle(request);
  });

  http.Response redirect(String to, {Map<String, String> headers = const {}}) =>
      http.Response('', 302, headers: {'location': to, ...headers});

  http.Response json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response serve(Map<String, dynamic> challenge) {
    _current = challenge;
    return json(challenge);
  }

  Map<String, dynamic> get afterPassword => otp
      ? {
          'component': 'ak-stage-authenticator-validate',
          'pending_user': 'wear',
          'device_challenges': [
            {'device_class': webauthnOnly ? 'webauthn' : 'totp'},
          ],
        }
      : {
          'component': 'xak-flow-redirect',
          'to': '/application/o/authorize/?again=1',
        };

  Future<http.Response> handle(http.Request r) async {
    final url = r.url.toString();
    final path = r.url.path;
    if (url.startsWith(fakeAbsUrl)) {
      switch (path) {
        case '/status':
          return json({
            'serverVersion': '2.37.2',
            'authMethods': [if (password) 'local', if (openid) 'openid'],
            if (buttonText != null || autoLaunch)
              'authFormData': {
                'authLoginCustomMessage': null,
                if (buttonText != null) 'authOpenIDButtonText': buttonText,
                if (autoLaunch) 'authOpenIDAutoLaunch': true,
              },
          });
        case '/auth/openid':
          final q = r.url.queryParameters;
          expect(q['redirect_uri'], ssoRedirectUri);
          expect(q['code_challenge_method'], 'S256');
          expect(q['response_type'], 'code');
          state = q['state'];
          challenge = q['code_challenge'];
          if (startStatus == 400) {
            return http.Response('Invalid redirect_uri', 400);
          }
          return redirect(
            idpAuthorizeUrl ?? '$fakeIdpUrl$authorizePath?client_id=abs',
            headers: {
              // Joined the way dart:io joins repeated headers.
              'set-cookie':
                  'auth_method=openid-mobile; Max-Age=315360000; Path=/; '
                  // No space after the comma, like dart:io joins headers.
                  // ignore: missing_whitespace_between_adjacent_strings
                  'Expires=Thu, 08 Nov 2036 10:00:00 GMT; HttpOnly,'
                  'connect.sid=s%3Aabc.def; Path=/; HttpOnly',
            },
          );
        case '/api/libraries':
          return json({
            'libraries': [
              {'id': 'lib1', 'name': 'Audiobooks', 'mediaType': 'book'},
            ],
          });
        case '/auth/openid/mobile-redirect':
          final q = r.url.queryParameters;
          return redirect(
            '$ssoRedirectUri?code=${q['code']}'
            '&state=${badState ? 'other' : q['state']}',
          );
        case '/auth/openid/callback':
          final q = r.url.queryParameters;
          final cookie = r.headers['Cookie'] ?? '';
          expect(cookie, contains('auth_method=openid-mobile'));
          expect(cookie, contains('connect.sid=s%3Aabc.def'));
          expect(q['state'], state);
          expect(q['code'], code);
          final verifier = q['code_verifier']!;
          final expected = base64Url
              .encode(sha256.convert(utf8.encode(verifier)).bytes)
              .replaceAll('=', '');
          expect(expected, challenge);
          if (callbackError != null) {
            return redirect('/login?error=$callbackError&autoLaunch=0');
          }
          return json({
            'user': {'username': 'wear', 'token': 'legacy-token'},
            'userDefaultLibraryId': 'lib1',
          });
      }
    }
    if (url.startsWith(fakeIdpUrl)) {
      if (path == '/application/o/authorize/') {
        if (r.url.queryParameters['again'] == '1') {
          _flow = 'consent';
          return redirect('/if/flow/consent-flow/?x=1');
        }
        return redirect('$idpPagePath?next=%2Fapplication%2Fo%2Fauthorize');
      }
      if (path.startsWith('/if/flow/') || path == idpPagePath) {
        return http.Response('<html>authentik</html>', 200);
      }
      if (path.startsWith('/api/v3/flows/executor/')) {
        expect(r.url.queryParameters['query'], isNotEmpty);
        if (r.method == 'GET') {
          if (_current != null && _current!['_next'] != null) {
            return serve(_current!['_next'] as Map<String, dynamic>);
          }
          return serve(
            _flow == 'auth'
                ? {
                    'component': 'ak-stage-identification',
                    'application_pre': 'Audiobookshelf',
                    'password_fields': passwordOnFirstPage,
                    'captcha_stage': null,
                  }
                : {'component': 'ak-stage-consent', 'token': 'consent-token'},
          );
        }
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        final next = switch (body['component']) {
          'ak-stage-identification' when passwordOnFirstPage =>
            body['password'] == 'secret'
                ? afterPassword
                : {
                    'component': 'ak-stage-identification',
                    'password_fields': true,
                    'response_errors': {
                      'non_field_errors': [
                        {'string': 'Invalid credentials', 'code': 'invalid'},
                      ],
                    },
                  },
          'ak-stage-identification' => {
            'component': 'ak-stage-password',
            'pending_user': body['uid_field'],
          },
          'ak-stage-password' when body['password'] == 'secret' =>
            afterPassword,
          'ak-stage-password' => {
            'component': 'ak-stage-password',
            'pending_user': 'wear',
            'response_errors': {
              'password': [
                {'string': 'Invalid password', 'code': 'invalid'},
              ],
            },
          },
          'ak-stage-authenticator-validate' => {
            'component': 'xak-flow-redirect',
            'to': '/application/o/authorize/?again=1',
          },
          'ak-stage-consent' => () {
            expect(body['token'], 'consent-token');
            return {
              'component': 'xak-flow-redirect',
              'to':
                  '$fakeAbsUrl/auth/openid/mobile-redirect?code=$code&state=$state',
            };
          }(),
          _ => fail('unexpected ${body['component']}'),
        };
        _passwordOk = _passwordOk || body['password'] == 'secret';
        // Authentik answers a POST with a redirect to GET the executor.
        _current = {'_next': next};
        return redirect(r.url.toString());
      }
    }
    return http.Response('not found: $url', 404);
  }
}
