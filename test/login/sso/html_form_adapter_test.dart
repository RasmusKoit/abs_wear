import 'package:abs_wear/login/data/sso/html_form_adapter.dart';
import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_form_idps.dart';
import '../../helpers/fake_sso_servers.dart';

Matcher _prompt(List<SsoField> fields, {bool retry = false, String? user}) =>
    isA<SsoPrompt>()
        .having((p) => p.fields, 'fields', fields)
        .having((p) => p.retry, 'retry', retry)
        .having((p) => p.user, 'user', user);

Matcher _error(SsoError error, [String? detail]) => isA<SsoException>()
    .having((e) => e.error, 'error', error)
    .having((e) => e.detail, 'detail', detail ?? anything);

String keycloakPage(String name) => recordedPage('keycloak', name);

const Map<SsoField, String> _login = {
  SsoField.username: 'wear',
  SsoField.password: 'secret',
};

void main() {
  group('Keycloak', () {
    test('logs in: username and password, consent, done', () async {
      final kc = FakeKeycloak();
      final (login, first) = await SsoLogin.start(
        fakeAbsUrl,
        client: kc.client,
      );
      expect(login.provider, 'Keycloak');
      expect(first, _prompt([SsoField.username, SsoField.password]));
      final consent = await login.submit(_login);
      expect(consent, isA<SsoConsent>());
      expect((consent as SsoConsent).app, 'Audiobookshelf');
      final done = await login.submit({});
      expect(done, isA<SsoDone>());
      expect(((done as SsoDone).data['user'] as Map)['token'], 'legacy-token');
      expect(kc.posts.first, {
        'credentialId': '',
        'username': 'wear',
        'password': 'secret',
        'login': '',
      });
      // The password went to Keycloak's form action and nowhere else.
      final withPassword = kc.requests.where((r) => r.body.contains('secret'));
      expect(withPassword.map((r) => r.url.path), [
        '/realms/abs/login-actions/authenticate',
      ]);
      login.close();
    });

    test('without a consent screen goes straight back', () async {
      final kc = FakeKeycloak(consent: false);
      final (login, _) = await SsoLogin.start(fakeAbsUrl, client: kc.client);
      expect(await login.submit(_login), isA<SsoDone>());
    });

    test('a wrong password shows the same form again: retry', () async {
      final kc = FakeKeycloak();
      final (login, _) = await SsoLogin.start(fakeAbsUrl, client: kc.client);
      expect(
        await login.submit({..._login, SsoField.password: 'nope'}),
        _prompt([SsoField.username, SsoField.password], retry: true),
      );
      expect(await login.submit(_login), isA<SsoConsent>());
    });

    test('asks for the OTP code, again when it is wrong', () async {
      final kc = FakeKeycloak(otp: true);
      final (login, _) = await SsoLogin.start(fakeAbsUrl, client: kc.client);
      expect(
        await login.submit({..._login, SsoField.username: 'wear-otp'}),
        _prompt([SsoField.code], user: 'wear-otp'),
      );
      expect(
        await login.submit({SsoField.code: '000000'}),
        _prompt([SsoField.code], user: 'wear-otp', retry: true),
      );
      expect(await login.submit({SsoField.code: '123456'}), isA<SsoConsent>());
      expect(await login.submit({}), isA<SsoDone>());
      expect(kc.posts[1], {
        'selectedCredentialId': 'f8bb8afd-96af-48e1-97ce-336781f412b2',
        'otp': '000000',
        'login': '',
      });
    });

    test('a required new password is unsupported', () async {
      final kc = FakeKeycloak(newPassword: true);
      final (login, _) = await SsoLogin.start(fakeAbsUrl, client: kc.client);
      await expectLater(
        login.submit(_login),
        throwsA(
          _error(SsoError.unsupportedStep, 'login-login-update-password'),
        ),
      );
    });
  });

  group('Gitea', () {
    const login = {SsoField.username: 'wear-gitea', SsoField.password: 'x'};

    test('logs in: wrong password, password, grant, done', () async {
      final gitea = FakeGitea();
      final (sso, first) = await SsoLogin.start(
        fakeAbsUrl,
        client: gitea.client,
      );
      expect(sso.provider, 'Gitea');
      expect(first, _prompt([SsoField.username, SsoField.password]));
      expect(
        await sso.submit(login),
        _prompt([SsoField.username, SsoField.password], retry: true),
      );
      final grant = await sso.submit({...login, SsoField.password: 'secret'});
      expect(grant, isA<SsoConsent>());
      expect((grant as SsoConsent).app, 'Audiobookshelf');
      expect(await sso.submit({}), isA<SsoDone>());
      expect(gitea.posts.last, {
        'client_id': '8d7bf838-d5bc-412c-b1f3-69525f046952',
        'state': 'WUcq3K6d23WqZcdgDU6WBPolbqZVCeVR',
        'scope': 'openid profile email',
        'nonce': '',
        'redirect_uri': 'http://abs.test/auth/openid/mobile-redirect',
        'granted': 'true',
      });
    });

    test('a TOTP code, then on to the app despite the home page', () async {
      final gitea = FakeGitea(otp: true);
      final (sso, _) = await SsoLogin.start(fakeAbsUrl, client: gitea.client);
      expect(
        await sso.submit({...login, SsoField.password: 'secret'}),
        _prompt([SsoField.code], user: 'wear-gitea'),
      );
      expect(
        await sso.submit({SsoField.code: '000000'}),
        _prompt([SsoField.code], user: 'wear-gitea', retry: true),
      );
      expect(await sso.submit({SsoField.code: '123456'}), isA<SsoConsent>());
      expect(await sso.submit({}), isA<SsoDone>());
    });
  });

  group('recognises', () {
    final context = IdpContext(SsoHttp(), (_) async => (null, null));
    String? provider(String url, String body) =>
        HtmlFormAdapter.forPage(SsoPage(Uri.parse(url), body), context)?.name;

    test("Keycloak's login and OTP pages", () {
      const url = 'http://idp.test/realms/abs/protocol/openid-connect/auth';
      expect(provider(url, keycloakPage('login')), 'Keycloak');
      expect(provider(url, keycloakPage('otp')), 'Keycloak');
    });

    test("Gitea's login page, not its other pages", () {
      const url = 'http://git.test/user/login?redirect_to=%2F';
      expect(provider(url, recordedPage('gitea', 'login')), 'Gitea');
      expect(provider(url, recordedPage('gitea', 'home')), isNull);
    });

    test('not an Authentik flow page', () {
      expect(
        provider(
          'http://idp.test/if/flow/default-authentication-flow/?next=%2F',
          '''
<html><head><title>authentik</title></head><body>
<ak-flow-executor flowSlug="default-authentication-flow"></ak-flow-executor>
</body></html>''',
        ),
        isNull,
      );
    });

    test('not an unknown site, even with a login form', () {
      const page = '''
<html><body><form action="/search"><input name="q"></form>
<form method="post" action="/session">
<input name="username"><input type="password" name="password">
<button>Sign in</button></form></body></html>''';
      expect(provider('http://example.test/login', page), isNull);
      expect(provider('http://example.test/', '<html>hello</html>'), isNull);
    });

    test('the other known providers by their markers', () {
      // From their templates (not recorded from the real servers).
      const fields = '''
<input name="login"><input type="password" name="password">''';
      expect(
        provider('http://git.test/user/login', '''
<form method="post" action="/user/login">
<input type="hidden" name="_csrf" value="x">$fields</form>
<a href="https://forgejo.org">Forgejo</a>'''),
        'Forgejo',
      );
      expect(
        provider('http://dex.test/dex/auth/local/login?back=&state=x', '''
<form method="post" action="/dex/auth/local/login?state=x">$fields</form>'''),
        'Dex',
      );
      expect(
        provider('http://cloud.test/login?redirect_url=x', '''
<form method="post" action="/login">
<input type="hidden" name="requesttoken" value="t">$fields</form>'''),
        'Nextcloud',
      );
    });
  });

  test('a page without a usable form is unsupported', () async {
    final page = SsoPage(
      Uri.parse('http://idp.test/realms/abs/login-actions/required-action'),
      keycloakPage('update_password'),
    );
    final adapter = HtmlFormAdapter.forPage(
      page,
      IdpContext(SsoHttp(), (_) async => (null, null)),
    )!;
    await expectLater(
      adapter.begin(page),
      throwsA(_error(SsoError.unsupportedStep, 'login-login-update-password')),
    );
  });

  test('a form posting to another server is not filled in', () async {
    final page = SsoPage(
      Uri.parse('http://idp.test/realms/abs/protocol/openid-connect/auth'),
      keycloakPage('login').replaceAll(
        'http://idp.test/realms/abs/login-actions/authenticate',
        'http://evil.test/collect',
      ),
    );
    final adapter = HtmlFormAdapter.forPage(
      page,
      IdpContext(SsoHttp(), (_) async => (null, null)),
    )!;
    await expectLater(
      adapter.begin(page),
      throwsA(_error(SsoError.unsupportedStep)),
    );
  });

  test('a captcha is unsupported', () async {
    final page = SsoPage(
      Uri.parse('http://idp.test/realms/abs/protocol/openid-connect/auth'),
      keycloakPage('login').replaceFirst(
        '</form>',
        '<div class="g-recaptcha" data-sitekey="k"></div></form>',
      ),
    );
    final adapter = HtmlFormAdapter.forPage(
      page,
      IdpContext(SsoHttp(), (_) async => (null, null)),
    )!;
    await expectLater(
      adapter.begin(page),
      throwsA(_error(SsoError.unsupportedStep, 'captcha')),
    );
  });
}
