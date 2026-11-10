import 'dart:convert';

import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const abs = 'http://abs.test';
const idp = 'http://idp.test';

/// A fake Audiobookshelf + Authentik pair answering like the real ones (the
/// challenges are trimmed copies of Authentik 2026.8's), with switches for
/// the failure cases.
class FakeServers {
  FakeServers({
    this.openid = true,
    this.startStatus = 302,
    this.webauthnOnly = false,
    this.otp = false,
    this.callbackError,
    this.code = 'the-code',
    this.badState = false,
    this.idpPagePath = '/if/flow/default-authentication-flow/',
  });

  final bool openid;
  final int startStatus;
  final bool webauthnOnly;
  final bool otp;
  final String? callbackError;
  final String code;
  final bool badState;
  final String idpPagePath;

  String? state;
  String? challenge;
  final requests = <http.Request>[];
  bool _passwordOk = false;
  String _flow = 'auth';
  Map<String, dynamic>? _current;

  late final client = MockClient((request) async {
    requests.add(request);
    expect(request.followRedirects, isFalse);
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
    if (url.startsWith(abs)) {
      switch (path) {
        case '/status':
          return json({
            'serverVersion': '2.37.2',
            'authMethods': ['local', if (openid) 'openid'],
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
            '$idp/application/o/authorize/?client_id=abs',
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
    if (url.startsWith(idp)) {
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
                    'password_fields': false,
                    'captcha_stage': null,
                  }
                : {'component': 'ak-stage-consent', 'token': 'consent-token'},
          );
        }
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        final next = switch (body['component']) {
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
              'to': '$abs/auth/openid/mobile-redirect?code=$code&state=$state',
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

Future<SsoStep> _expectPrompt(
  Future<SsoStep> step,
  List<SsoField> fields, {
  bool retry = false,
}) async {
  final s = await step;
  expect(s, isA<SsoPrompt>());
  final prompt = s as SsoPrompt;
  expect(prompt.fields, fields);
  expect(prompt.retry, retry);
  return s;
}

void main() {
  test('logs in through Authentik: username, password, consent', () async {
    final servers = FakeServers();
    final (login, first) = await SsoLogin.start(abs, client: servers.client);
    await _expectPrompt(Future.value(first), [SsoField.username]);
    final pw = await login.submit({SsoField.username: 'wear'});
    expect((pw as SsoPrompt).user, 'wear');
    expect(pw.fields, [SsoField.password]);
    final consent = await login.submit({SsoField.password: 'secret'});
    expect(consent, isA<SsoConsent>());
    expect((consent as SsoConsent).app, 'Audiobookshelf');
    final done = await login.submit({});
    expect(done, isA<SsoDone>());
    final data = (done as SsoDone).data;
    expect((data['user'] as Map)['token'], 'legacy-token');
    login.close();
  });

  test('a wrong password asks again', () async {
    final servers = FakeServers();
    final (login, _) = await SsoLogin.start(abs, client: servers.client);
    await login.submit({SsoField.username: 'wear'});
    await _expectPrompt(login.submit({SsoField.password: 'nope'}), [
      SsoField.password,
    ], retry: true);
    expect(
      await login.submit({SsoField.password: 'secret'}),
      isA<SsoConsent>(),
    );
  });

  test('asks for a TOTP code when the account has one', () async {
    final servers = FakeServers(otp: true);
    final (login, _) = await SsoLogin.start(abs, client: servers.client);
    await login.submit({SsoField.username: 'wear'});
    await _expectPrompt(login.submit({SsoField.password: 'secret'}), [
      SsoField.code,
    ]);
    expect(await login.submit({SsoField.code: '123456'}), isA<SsoConsent>());
  });

  test('a passkey-only account is unsupported on the watch', () async {
    final servers = FakeServers(otp: true, webauthnOnly: true);
    final (login, _) = await SsoLogin.start(abs, client: servers.client);
    await login.submit({SsoField.username: 'wear'});
    await expectLater(
      login.submit({SsoField.password: 'secret'}),
      throwsA(_error(SsoError.unsupportedStep)),
    );
  });

  test('a server without SSO', () async {
    final servers = FakeServers(openid: false);
    await expectLater(
      SsoLogin.start(abs, client: servers.client),
      throwsA(_error(SsoError.notEnabled)),
    );
  });

  test('a server that does not allow the redirect URI yet', () async {
    final servers = FakeServers(startStatus: 400);
    await expectLater(
      SsoLogin.start(abs, client: servers.client),
      throwsA(_error(SsoError.redirectNotAllowed)),
    );
  });

  test('an identity provider the watch cannot drive', () async {
    final servers = FakeServers(idpPagePath: '/realms/x/login');
    await expectLater(
      SsoLogin.start(abs, client: servers.client),
      throwsA(_error(SsoError.unsupportedProvider)),
    );
  });

  Future<void> loginExpecting(FakeServers servers, SsoError error) async {
    final (login, _) = await SsoLogin.start(abs, client: servers.client);
    await login.submit({SsoField.username: 'wear'});
    await login.submit({SsoField.password: 'secret'});
    await expectLater(login.submit({}), throwsA(_error(error)));
  }

  test('no Audiobookshelf account for the SSO user', () async {
    await loginExpecting(
      FakeServers(callbackError: 'Unauthorized'),
      SsoError.noAccount,
    );
  });

  test('a redirect back with another state is refused', () async {
    await loginExpecting(FakeServers(badState: true), SsoError.failed);
  });

  test('an identity provider error (code "undefined") fails', () async {
    await loginExpecting(FakeServers(code: 'undefined'), SsoError.failed);
  });
}

Matcher _error(SsoError error) =>
    isA<SsoException>().having((e) => e.error, 'error', error);
