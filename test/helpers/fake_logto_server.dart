import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fake_sso_servers.dart';

/// Logto 1.46's sign-in page (trimmed): its sign-in app with the settings
/// embedded as `window.logtoSsr`.
const logtoSignInPage = '''
<!DOCTYPE html>
<html lang="en" translate="no">
<head>
  <meta charset="utf-8" />
  <title></title>
  <script>
    /* See {@link packages/schemas/src/types/ssr.ts} */
    window.logtoSsr = Object.freeze({"signInExperience":{"appId":"abs","data":{"tenantId":"default","id":"default","signInMode":"SignInAndRegister"}}});
  </script>
  <script type="module" crossorigin src="/assets/index-E5p9h-_W.js"></script>
</head>
<body><div id="app"></div></body>
</html>
''';

/// The username + password method of Logto's sign-in settings.
const Map<String, Object> logtoUsernamePassword = {
  'identifier': 'username',
  'password': true,
  'verificationCode': false,
  'isPasswordPrimary': true,
};

/// Audiobookshelf with Logto as its identity provider, answering like the
/// real ones (the responses are trimmed copies of Logto 1.46's).
class FakeLogto extends FakeServers {
  FakeLogto({
    this.ssr = true,
    this.captcha = false,
    this.terms = 'Automatic',
    this.methods = const [logtoUsernamePassword],
    this.totp = false,
    this.factors = const ['Totp'],
    this.suggestMfa = false,
    this.passkeyPreferred = false,
    this.mfaSetup = false,
    this.mfaSetupSkippable = false,
    this.consent = false,
    this.organizations = const [],
  }) : super(authorizePath: '/oidc/auth');

  /// The sign-in page embeds `window.logtoSsr` (older Logto doesn't).
  final bool ssr;
  final bool captcha;

  /// `agreeToTermsPolicy`, with terms of use and a privacy policy set.
  final String terms;
  final List<Map<String, Object>> methods;

  /// The user has an authenticator app; [factors] are what Logto offers.
  final bool totp;
  final List<String> factors;

  /// Logto suggests adding MFA to the account.
  final bool suggestMfa;

  /// Passkey sign-in is on and the user has no passkey yet.
  final bool passkeyPreferred;

  /// Logto wants the user to set up MFA (skippable or not).
  final bool mfaSetup;
  final bool mfaSetupSkippable;

  /// A third-party app: Logto asks for consent.
  final bool consent;
  final List<Map<String, Object>> organizations;

  bool _identified = false;
  bool _totpOk = false;
  bool _mfaSkipped = false;
  bool _passkeySkipped = false;

  Map<String, dynamic> get signInExperience => {
    'tenantId': 'default',
    'id': 'default',
    'signIn': {'methods': methods},
    'signUp': {
      'identifiers': ['username'],
      'password': true,
      'verify': false,
    },
    'signInMode': 'SignInAndRegister',
    'mfa': {
      'factors': ['Totp'],
      'policy': 'UserControlled',
    },
    'captchaPolicy': {'enabled': captcha},
    'agreeToTermsPolicy': terms,
    'termsOfUseUrl': 'https://abs-wear.test/terms',
    'privacyPolicyUrl': null,
    'passkeySignIn': passkeyPreferred
        ? {'enabled': true, 'showPasskeyButton': true, 'allowAutofill': false}
        : <String, dynamic>{},
    if (captcha)
      'captchaConfig': {
        'type': 'Turnstile',
        'siteKey': '1x00000000000000000000AA',
      },
  };

  http.Response error(
    int status,
    String code,
    String message, [
    Object? data,
  ]) => http.Response(
    jsonEncode({'code': code, 'message': message, 'data': ?data}),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response get noContent => http.Response('', 204);

  Map<String, dynamic> body(http.Request r) =>
      r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;

  @override
  Future<http.Response> handle(http.Request r) async {
    if (!r.url.toString().startsWith(fakeIdpUrl)) {
      return await super.handle(r);
    }
    final path = r.url.path;
    final route = '${r.method} $path';
    if (path.startsWith('/api/experience')) {
      // The interaction lives in the cookies /oidc/auth set.
      expect(r.headers['Cookie'], contains('_interaction=int-1'));
    }
    switch (route) {
      case 'GET /oidc/auth':
        expect(r.url.queryParameters['client_id'], 'abs');
        return http.Response(
          'Redirecting to /sign-in?app_id=abs.',
          303,
          headers: {
            'location': '/sign-in?app_id=abs',
            // Joined the way dart:io joins repeated headers.
            'set-cookie': [
              '_logto=eyJhcHBJZCI6ImFicyJ9; path=/; httponly',
              '_interaction=int-1; path=/; httponly',
            ].join(','),
          },
        );
      case 'GET /sign-in':
        return http.Response(
          ssr ? logtoSignInPage : '<!DOCTYPE html><div id="app"></div>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      case 'GET /api/.well-known/sign-in-exp':
        return json(signInExperience);
      case 'PUT /api/experience':
        expect(body(r), {'interactionEvent': 'SignIn'});
        return noContent;
      case 'POST /api/experience/verification/password':
        final b = body(r);
        final id = b['identifier'] as Map<String, dynamic>;
        final email = methods.first['identifier'] == 'email';
        expect(id['type'], email ? 'email' : 'username');
        final user = email ? 'wear@abs-wear.test' : 'wear';
        if (id['value'] != user || b['password'] != 'secret') {
          return error(
            422,
            'session.invalid_credentials',
            'Incorrect account or password. Please check your input.',
          );
        }
        return json({'verificationId': 'pw-1'});
      case 'POST /api/experience/identification':
        expect(body(r), {'verificationId': 'pw-1'});
        _identified = true;
        return noContent;
      case 'POST /api/experience/verification/totp/verify':
        if (body(r)['code'] != '123456') {
          return error(400, 'session.mfa.invalid_totp_code', 'Invalid code.');
        }
        _totpOk = true;
        return json({'verificationId': 'totp-1'});
      case 'POST /api/experience/profile/mfa/mfa-skipped':
        // Logto refuses it for anything but the optional suggestion here.
        expect(suggestMfa, isTrue);
        _mfaSkipped = true;
        return noContent;
      case 'POST /api/experience/profile/mfa/passkey-skipped':
        _passkeySkipped = true;
        return noContent;
      case 'POST /api/experience/submit':
        expect(_identified, isTrue);
        if (passkeyPreferred && !_passkeySkipped) {
          return error(
            422,
            'user.passkey_preferred',
            'Passkey sign-in is preferred. Please bind a passkey.',
          );
        }
        if (totp && !_totpOk) {
          return error(
            403,
            'session.mfa.require_mfa_verification',
            'Mfa verification is required to sign in.',
            {
              'availableFactors': factors,
              'maskedIdentifiers': <String, String>{},
            },
          );
        }
        if (mfaSetup && !_mfaSkipped) {
          return error(
            422,
            'user.missing_mfa',
            'You need to bind additional MFA before signing-in.',
            {
              'availableFactors': ['Totp'],
              if (mfaSetupSkippable) 'skippable': true,
            },
          );
        }
        if (suggestMfa && !_mfaSkipped) {
          return error(
            422,
            'user.suggest_mfa',
            'For better account security, we recommend binding MFA to '
                'your account.',
          );
        }
        return json({'redirectTo': '$fakeIdpUrl/oidc/auth/uid-1'});
      case 'GET /oidc/auth/uid-1':
        return redirect('/consent?app_id=abs');
      case 'GET /consent':
        // First-party apps go straight on.
        if (!consent) return redirect('$fakeIdpUrl/oidc/auth/uid-2');
        return http.Response(logtoSignInPage, 200);
      case 'GET /api/interaction/consent':
        return json({
          'application': {'id': 'abs', 'name': 'Audiobookshelf'},
          'user': {'id': 'u1', 'username': 'wear'},
          'organizations': organizations,
          'missingOIDCScope': ['profile', 'email'],
          'missingResourceScopes': <Object>[],
          'redirectUri': '$fakeAbsUrl/auth/openid/mobile-redirect',
        });
      case 'POST /api/interaction/consent':
        return json({'redirectTo': '$fakeIdpUrl/oidc/auth/uid-2'});
      case 'GET /oidc/auth/uid-2':
        return http.Response(
          '',
          303,
          headers: {
            'location':
                '$fakeAbsUrl/auth/openid/mobile-redirect?code=$code'
                '&state=$state&iss=${Uri.encodeComponent('$fakeIdpUrl/oidc')}',
          },
        );
    }
    return http.Response('not found: $route', 404);
  }
}
