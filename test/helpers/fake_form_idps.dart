import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_sso_servers.dart' show fakeAbsUrl, fakeIdpUrl;

const fakeGiteaUrl = 'http://git.test';

/// A page recorded from the real provider ("keycloak" 26.8 or "gitea"
/// 1.27; trimmed, hosts replaced).
String recordedPage(String provider, String name) =>
    File('test/login/sso/fixtures/$provider/$name.html').readAsStringSync();

/// A fake Audiobookshelf in front of a server-rendered identity provider,
/// which answers with the pages, statuses and redirects recorded from a
/// real login.
abstract class FakeFormIdp {
  FakeFormIdp(this.provider, this.user, {this.app = 'Audiobookshelf'});

  /// The fixture folder.
  final String provider;

  /// The OAuth2 client's name on the consent page (recorded as
  /// "Audiobookshelf").
  final String app;

  /// Who ends up logged in to ABS.
  final String user;

  String? state;
  String? challenge;
  final requests = <http.Request>[];

  /// The form fields of each POST to the identity provider, in order.
  final posts = <Map<String, String>>[];

  late final client = MockClient((request) async {
    requests.add(request);
    expect(request.followRedirects, isFalse);
    if (!request.url.toString().startsWith(fakeAbsUrl)) {
      if (request.method == 'POST') {
        expect(
          request.headers['content-type'],
          startsWith('application/x-www-form-urlencoded'),
        );
        posts.add(Uri.splitQueryString(request.body));
      }
      return await idp(request);
    }
    return _abs(request);
  });

  /// Where ABS sends the browser to log in.
  String get authorizeUrl;

  /// The identity provider's answer to [r].
  Future<http.Response> idp(http.Request r);

  static const codeBack = 'idp-code';

  http.Response redirect(
    String to, {
    int status = 302,
    Map<String, String> headers = const {},
  }) => http.Response('', status, headers: {'location': to, ...headers});

  http.Response page(String name, {Map<String, String> headers = const {}}) =>
      http.Response(
        recordedPage(provider, name).replaceAll('Audiobookshelf', app),
        200,
        headers: {'content-type': 'text/html;charset=utf-8', ...headers},
      );

  /// The identity provider's redirect back to ABS with a code.
  http.Response backToAbs({int status = 302}) => redirect(
    '$fakeAbsUrl/auth/openid/mobile-redirect?state=abs-state&code=$codeBack',
    status: status,
  );

  http.Response _abs(http.Request r) {
    switch (r.url.path) {
      case '/status':
        return http.Response(
          jsonEncode({
            'authMethods': ['local', 'openid'],
          }),
          200,
        );
      case '/auth/openid':
        state = r.url.queryParameters['state'];
        challenge = r.url.queryParameters['code_challenge'];
        return redirect(
          authorizeUrl,
          headers: {'set-cookie': 'connect.sid=s%3Aabc; Path=/; HttpOnly'},
        );
      case '/auth/openid/mobile-redirect':
        expect(r.url.queryParameters['code'], codeBack);
        return redirect('$ssoRedirectUri?code=$codeBack&state=$state');
      case '/auth/openid/callback':
        final q = r.url.queryParameters;
        expect(r.headers['Cookie'], contains('connect.sid=s%3Aabc'));
        expect(q['code'], codeBack);
        final verifier = q['code_verifier']!;
        expect(
          base64Url
              .encode(sha256.convert(utf8.encode(verifier)).bytes)
              .replaceAll('=', ''),
          challenge,
        );
        return http.Response(
          jsonEncode({
            'user': {'username': user, 'token': 'legacy-token'},
            'userDefaultLibraryId': 'lib1',
          }),
          200,
        );
    }
    return http.Response('not found: ${r.url}', 404);
  }
}

/// Keycloak 26.8, realm "abs".
class FakeKeycloak extends FakeFormIdp {
  FakeKeycloak({
    this.otp = false,
    this.consent = true,
    this.newPassword = false,
    this.terms = false,
    super.app,
  }) : super('keycloak', otp ? 'wear-otp' : 'wear');

  /// The user has a TOTP code (the recorded OTP pages are "wear-otp"'s).
  final bool otp;

  /// The client asks for consent ("Consent required").
  final bool consent;

  /// The user must set a new password first (a required action).
  final bool newPassword;

  /// The realm makes the user accept its terms and conditions (a required
  /// action).
  final bool terms;

  static const _realm = '$fakeIdpUrl/realms/abs';

  @override
  String get authorizeUrl =>
      '$_realm/protocol/openid-connect/auth?client_id=abs'
      '&scope=openid%20profile%20email&response_type=code'
      '&redirect_uri=http%3A%2F%2Fabs.test%2Fauth%2Fopenid'
      '%2Fmobile-redirect&state=abs-state';

  /// Where Keycloak sends the browser once the password (and code) is right.
  http.Response _loggedIn() => switch ((newPassword, consent)) {
    _ when terms => redirect(
      '$_realm/login-actions/required-action?execution=TERMS_AND_CONDITIONS',
    ),
    (true, _) => redirect(
      '$_realm/login-actions/required-action?execution=UPDATE_PASSWORD',
    ),
    (_, true) => redirect(
      '$_realm/login-actions/required-action?execution=OAUTH_GRANT',
    ),
    _ => backToAbs(),
  };

  @override
  Future<http.Response> idp(http.Request r) async {
    final path = r.url.path;
    // Keycloak's login session cookie, as set on the first page.
    if (path != '/realms/abs/protocol/openid-connect/auth') {
      expect(r.headers['Cookie'], contains('AUTH_SESSION_ID=kc-session'));
    }
    switch (path) {
      case '/realms/abs/protocol/openid-connect/auth':
        return page(
          'login',
          headers: {
            'set-cookie':
                'AUTH_SESSION_ID=kc-session;Version=1;Path=/realms/abs/;'
                'HttpOnly;SameSite=Lax',
          },
        );
      case '/realms/abs/login-actions/required-action':
        return switch (r.url.queryParameters['execution']) {
          'OAUTH_GRANT' => page('consent'),
          'UPDATE_PASSWORD' => page('update_password'),
          'TERMS_AND_CONDITIONS' => page('terms'),
          _ => http.Response('unknown action', 400),
        };
      case '/realms/abs/login-actions/authenticate':
        expect(r.url.queryParameters['session_code'], isNotEmpty);
        final form = posts.last;
        if (form.containsKey('otp')) {
          expect(
            form['selectedCredentialId'],
            'f8bb8afd-96af-48e1-97ce-336781f412b2',
          );
          return form['otp'] == '123456' ? _loggedIn() : page('otp_error');
        }
        // The hidden field and the button are sent along, like a browser.
        expect(form['credentialId'], '');
        expect(form['login'], '');
        if (form['password'] != 'secret') return page('login_error');
        return otp ? page('otp') : _loggedIn();
      case '/realms/abs/login-actions/consent':
        final form = posts.last;
        expect(form['code'], 'K0oQdeuOBbZJ_iADEgR_sjLZloxvhN4230t5R58UCNo');
        expect(form.containsKey('accept'), isTrue);
        expect(form.containsKey('cancel'), isFalse);
        return backToAbs();
    }
    return http.Response('not found: ${r.url}', 404);
  }
}

/// Gitea 1.27 as the OpenID provider, with a not yet granted OAuth2 app.
class FakeGitea extends FakeFormIdp {
  FakeGitea({this.otp = false, super.app})
    : super('gitea', otp ? 'wear-gitea-otp' : 'wear-gitea');

  /// The user has a TOTP code.
  final bool otp;

  bool _signedIn = false;

  static const _authorize =
      '/login/oauth/authorize?client_id=8d7bf838&scope=openid+profile+email'
      '&response_type=code&redirect_uri=http%3A%2F%2Fabs.test%2Fauth%2Fopenid'
      '%2Fmobile-redirect&state=abs-state';

  @override
  String get authorizeUrl => '$fakeGiteaUrl$_authorize';

  @override
  Future<http.Response> idp(http.Request r) async {
    expect(r.url.toString(), startsWith(fakeGiteaUrl));
    switch ((r.method, r.url.path)) {
      case ('GET', '/login/oauth/authorize'):
        if (!_signedIn) {
          return redirect(
            '/user/login?redirect_to=${Uri.encodeComponent(_authorize)}',
            status: 303,
          );
        }
        return page('grant');
      case ('GET', '/user/login'):
        return page(
          'login',
          headers: {'set-cookie': 'i_like_gitea=sess; Path=/; HttpOnly'},
        );
      case ('POST', '/user/login'):
        // The unticked "remember" box and the unnamed button aren't sent.
        expect(posts.last.keys, ['user_name', 'password']);
        if (posts.last['password'] != 'secret') return page('login_error');
        if (otp) return redirect('/user/two_factor', status: 303);
        _signedIn = true;
        return redirect(_authorize, status: 303);
      case ('GET', '/user/two_factor'):
        return page('two_factor');
      case ('POST', '/user/two_factor'):
        if (posts.last['passcode'] != '123456') {
          return page('two_factor_error');
        }
        _signedIn = true;
        // Gitea forgets the redirect_to after a TOTP code.
        return redirect('/', status: 303);
      case ('GET', '/'):
        return page('home');
      case ('POST', '/login/oauth/grant'):
        expect(r.headers['Cookie'], contains('i_like_gitea=sess'));
        expect(posts.last['granted'], 'true');
        expect(posts.last['client_id'], '8d7bf838-d5bc-412c-b1f3-69525f046952');
        return backToAbs(status: 303);
    }
    return http.Response('not found: ${r.url}', 404);
  }
}
