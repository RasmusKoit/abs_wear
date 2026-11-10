import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fake_sso_servers.dart';

const fakeAutheliaUrl = 'https://auth.test';
const _flowId = '5d3a1a33-8472-48c1-9f71-fb2015edeb3e';

/// Authelia's portal page (trimmed from Authelia 4.39.28): a React app
/// with its settings on `<body>` and `<base href>` at the portal's root.
String autheliaPortalHtml(String root) =>
    '''
<!--
SPDX-FileCopyrightText: 2026 Authelia

SPDX-License-Identifier: Apache-2.0
-->

<!doctype html>
<html lang="en">
    <head>
        <base href="$root/" />
        <meta property="csp-nonce" content="LScyyIpeBwJJ2sOtWUX9oYSVEKSDjpSt" />
        <meta charset="utf-8" />
        <title></title>
      <script type="module" crossorigin src="./static/js/index.CH9gMMud.js"></script>
      <link rel="stylesheet" crossorigin href="./static/css/index.DtbinVJv.css">
    </head>

    <body
        data-basepath=""
        data-duoselfenrollment="false"
        data-logooverride="false"
        data-passkeylogin="false"
        data-rememberme="true"
        data-resetpassword="true"
        data-theme="light"
    >
        <noscript>You need to enable JavaScript to run this app.</noscript>
        <div id="root"></div>
    </body>
</html>
''';

/// The second factor the fake Authelia user has.
enum AutheliaSecondFactor { none, totp, webauthn, duo }

/// Audiobookshelf ([FakeServers]) in front of a fake Authelia answering
/// like Authelia 4.39.28's API (the bodies are trimmed copies of real
/// answers), the portal served under [basePath].
class FakeAutheliaServers extends FakeServers {
  FakeAutheliaServers({
    this.secondFactor = AutheliaSecondFactor.none,
    this.consent = true,
    this.requireLogin = false,
    this.basePath = '',
    this.badFlow = false,
    this.baseHref,
    this.claims = false,
    this.noRedirect = false,
  });

  final AutheliaSecondFactor secondFactor;

  /// The client's consent_mode is explicit (else implicit).
  final bool consent;

  /// The consent screen wants the user to log in again (prompt=login).
  final bool requireLogin;
  final String basePath;

  /// Authelia no longer knows the flow (expired).
  final bool badFlow;

  /// The portal's `<base href>`, if not its own root.
  final String? baseHref;

  /// The consent screen lists claims to grant (else null, as seen live).
  final bool claims;

  /// A correct TOTP code gets a bare `{"status":"OK"}`, no redirect.
  final bool noRedirect;

  final firstFactorBodies = <Map<String, dynamic>>[];
  bool _consented = false;
  int _level = 0;

  String get _root => '$fakeAutheliaUrl$basePath';

  String get _authorize {
    const back = '$fakeAbsUrl/auth/openid/mobile-redirect';
    return '$_root/api/oidc/authorization?client_id=abs'
        '&redirect_uri=${Uri.encodeQueryComponent(back)}'
        '&response_type=code&scope=openid+profile+email&state=$state';
  }

  http.Response _ok([Map<String, dynamic>? data]) =>
      json({'status': 'OK', 'data': ?data});

  http.Response _ko(int status, String message) => http.Response(
    jsonEncode({'status': 'KO', 'message': message}),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response _seeOther(String to) => http.Response(
    '<a href="$to">See Other</a>.',
    303,
    headers: {'location': to, 'content-type': 'text/html; charset=utf-8'},
  );

  @override
  Future<http.Response> handle(http.Request r) async {
    final url = r.url.toString();
    if (url.startsWith(fakeAbsUrl) && r.url.path == '/auth/openid') {
      // The real start (cookies, state), pointed at Authelia instead.
      final start = await super.handle(r);
      return http.Response(
        '',
        302,
        headers: {...start.headers, 'location': _authorize},
      );
    }
    if (!url.startsWith(fakeAutheliaUrl)) return await super.handle(r);
    expect(r.followRedirects, isFalse);
    final path = r.url.path;
    if (!path.startsWith('$basePath/')) return http.Response('', 404);
    final route = path.substring(basePath.length);
    final q = r.url.queryParameters;
    final body = r.method == 'POST'
        ? jsonDecode(r.body) as Map<String, dynamic>
        : const <String, dynamic>{};
    if (route.startsWith('/api/') &&
        route != '/api/oidc/authorization' &&
        route != '/api/firstfactor') {
      expect(r.headers['Cookie'], contains('authelia_session='));
    }
    switch ((r.method, route)) {
      case ('GET', '/api/oidc/authorization'):
        if (q['consent_id'] == null) {
          return _seeOther('$_root/?flow=openid_connect&flow_id=$_flowId');
        }
        expect(q['consent_id'], _flowId);
        if (consent && !_consented) {
          return _seeOther(
            '$_root/consent/openid/decision'
            '?flow=openid_connect&flow_id=$_flowId',
          );
        }
        return _seeOther(
          '$fakeAbsUrl/auth/openid/mobile-redirect?code=$code'
          '&iss=${Uri.encodeQueryComponent(fakeAutheliaUrl)}'
          '&scope=openid+profile+email&state=$state',
        );
      case ('GET', '/' || '/consent/openid/decision'):
        expect(q['flow'], 'openid_connect');
        return http.Response(
          autheliaPortalHtml(baseHref ?? _root),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      case ('POST', '/api/firstfactor'):
        firstFactorBodies.add(body);
        if (badFlow) {
          // Really a 200 with "KO" when the flow id is unknown.
          return http.Response(
            jsonEncode({
              'status': 'KO',
              'message': 'Authentication failed. Check your credentials.',
            }),
            200,
          );
        }
        expect(body['flowID'], _flowId);
        expect(body['flow'], 'openid_connect');
        if (body['username'] != 'wear' || body['password'] != 'secret') {
          return _ko(401, 'Authentication failed. Check your credentials.');
        }
        _level = 1;
        final cookie = {
          'set-cookie':
              'authelia_session=sess1; expires=Tue, 10 Nov 2026 22:36:09 GMT; '
              'domain=auth.test; path=/; HttpOnly; secure; SameSite=Lax',
        };
        if (secondFactor != AutheliaSecondFactor.none) {
          return http.Response('{"status":"OK"}', 200, headers: cookie);
        }
        return http.Response(
          jsonEncode({
            'status': 'OK',
            'data': {'redirect': '$_authorize&consent_id=$_flowId'},
          }),
          200,
          headers: cookie,
        );
      case ('POST', '/api/user/info'):
        return _ok({
          'display_name': 'ABS Wear',
          'emails': null,
          'method': switch (secondFactor) {
            AutheliaSecondFactor.duo => 'mobile_push',
            AutheliaSecondFactor.webauthn => 'webauthn',
            _ => 'totp',
          },
          'has_totp': secondFactor == AutheliaSecondFactor.totp,
          'has_webauthn': secondFactor == AutheliaSecondFactor.webauthn,
          'has_duo': secondFactor == AutheliaSecondFactor.duo,
        });
      case ('GET', '/api/configuration'):
        expect(_level, 1);
        return _ok({
          'available_methods': ['totp', 'webauthn', 'mobile_push'],
          'password_change_disabled': false,
          'password_reset_disabled': false,
        });
      case ('POST', '/api/secondfactor/totp'):
        expect(body['flowID'], _flowId);
        // Authelia checks the length first: 6 or 8 digits (empty is a 403).
        final token = body['token'] as String;
        if (token.isNotEmpty && token.length != 6 && token.length != 8) {
          return _ko(400, 'Authentication failed, please retry later.');
        }
        if (token != '123456') {
          return _ko(403, 'Authentication failed, please retry later.');
        }
        _level = 2;
        if (noRedirect) return _ok();
        return _ok({'redirect': '$_authorize&consent_id=$_flowId'});
      case ('GET', '/api/oidc/consent'):
        expect(q['flow_id'], _flowId);
        return _ok({
          'client_id': 'abs',
          'client_description': 'Audiobookshelf',
          'scopes': ['openid', 'profile', 'email'],
          'audience': <String>[],
          'resource': <String>[],
          'pre_configuration': false,
          'claims': claims ? ['groups', 42] : null,
          'essential_claims': claims ? ['email'] : null,
          'require_login': requireLogin,
        });
      case ('POST', '/api/oidc/consent'):
        expect(body, {
          'flow_id': _flowId,
          'client_id': 'abs',
          'consent': true,
          'pre_configure': false,
          if (claims) 'claims': ['email', 'groups'],
        });
        _consented = true;
        return _ok({'redirect_uri': '$_authorize&consent_id=$_flowId'});
    }
    return http.Response('404 Not Found', 404);
  }
}
