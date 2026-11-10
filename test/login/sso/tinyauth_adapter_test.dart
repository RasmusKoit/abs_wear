import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:abs_wear/login/data/sso/tinyauth_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_tinyauth.dart';

const Map<SsoField, String> _login = {
  SsoField.username: 'wear',
  SsoField.password: 'secret',
};

void main() {
  Future<(SsoLogin, SsoStep)> start(FakeTinyauth fake) =>
      SsoLogin.start('http://abs.test', client: fake.client);

  test('logs in: username and password, consent, done', () async {
    final fake = FakeTinyauth();
    final (login, first) = await start(fake);
    expect(login.provider, 'Tinyauth');
    expect((first as SsoPrompt).fields, [SsoField.username, SsoField.password]);
    expect(first.retry, isFalse);
    final consent = await login.submit(_login);
    expect((consent as SsoConsent).app, 'Audiobookshelf');
    final done = await login.submit({});
    expect(done, isA<SsoDone>());
    expect(((done as SsoDone).data['user'] as Map)['token'], 'legacy-token');
    // The password went to tinyauth's login endpoint only.
    final withPassword = fake.requests.where((r) => r.body.contains('secret'));
    expect(withPassword.map((r) => r.url.toString()), [
      '$fakeTinyauthUrl/api/user/login',
    ]);
    login.close();
  });

  test('a remembered consent goes straight back to the server', () async {
    final (login, _) = await start(FakeTinyauth(consentRemembered: true));
    expect(await login.submit(_login), isA<SsoDone>());
  });

  test('a wrong password asks again', () async {
    final (login, _) = await start(FakeTinyauth());
    final again = await login.submit({
      SsoField.username: 'wear',
      SsoField.password: 'nope',
    });
    expect((again as SsoPrompt).fields, [SsoField.username, SsoField.password]);
    expect(again.retry, isTrue);
    expect(await login.submit(_login), isA<SsoConsent>());
  });

  test('asks for the TOTP code, again when it is wrong', () async {
    final (login, _) = await start(FakeTinyauth(totp: true));
    final code = await login.submit(_login);
    expect((code as SsoPrompt).fields, [SsoField.code]);
    expect(code.user, 'wear');
    expect(code.retry, isFalse);
    final again = await login.submit({SsoField.code: '000000'});
    expect((again as SsoPrompt).fields, [SsoField.code]);
    expect(again.retry, isTrue);
    expect(await login.submit({SsoField.code: '123456'}), isA<SsoConsent>());
    expect(await login.submit({}), isA<SsoDone>());
  });

  test('a locked-out account fails', () async {
    final (login, _) = await start(FakeTinyauth(lockedOut: true));
    await expectLater(login.submit(_login), throwsA(_error(SsoError.failed)));
  });

  test("an expired ticket fails with tinyauth's message", () async {
    final (login, _) = await start(FakeTinyauth(ticketExpired: true));
    await login.submit(_login);
    await expectLater(
      login.submit({}),
      throwsA(
        _error(
          SsoError.failed,
        ).having((e) => e.detail, 'detail', contains('expired')),
      ),
    );
  });

  test("tinyauth's error page fails with its message", () async {
    await expectLater(
      start(
        FakeTinyauth(
          authorizeError: 'The provided redirect URI is not trusted',
        ),
      ),
      throwsA(
        _error(
          SsoError.failed,
        ).having((e) => e.detail, 'detail', contains('not trusted')),
      ),
    );
  });

  test('OAuth-only logins are unsupported on the watch', () async {
    await expectLater(
      start(
        FakeTinyauth(
          providers: const [
            {'name': 'GitHub', 'id': 'github', 'oauth': true},
          ],
        ),
      ),
      throwsA(_error(SsoError.unsupportedStep)),
    );
    await expectLater(
      start(
        FakeTinyauth(
          providers: const [
            {'name': 'Local', 'id': 'local', 'oauth': false},
            {'name': 'GitHub', 'id': 'github', 'oauth': true},
          ],
          autoRedirect: 'github',
        ),
      ),
      throwsA(_error(SsoError.unsupportedStep)),
    );
  });

  group('recognises', () {
    final context = IdpContext(SsoHttp(), (_) async => (null, null));
    IdpAdapter? adapterFor(String url, String body) =>
        TinyauthAdapter.forPage(SsoPage(Uri.parse(url), body), context);
    const authorize =
        '$fakeTinyauthUrl/oidc/authorize?login_for=oidc'
        '&oidc_name=Audiobookshelf&oidc_scope=openid&oidc_ticket=t';

    test("tinyauth's authorize and error pages", () {
      expect(adapterFor(authorize, tinyauthHtml), isA<TinyauthAdapter>());
      expect(
        adapterFor('$fakeTinyauthUrl/error?error=x', tinyauthHtml),
        isNotNull,
      );
    });

    test('nobody else', () {
      expect(
        adapterFor(
          'http://idp.test/if/flow/default-authentication-flow/',
          '<html>authentik</html>',
        ),
        isNull,
      );
      expect(adapterFor(authorize, '<html><p>hello</p></html>'), isNull);
      expect(
        adapterFor('http://example.test/login', '<html>Tinyauth</html>'),
        isNull,
      );
      // tinyauth's page without a ticket (not an OpenID login).
      expect(
        adapterFor('$fakeTinyauthUrl/oidc/authorize', tinyauthHtml),
        isNull,
      );
    });
  });
}

TypeMatcher<SsoException> _error(SsoError error) =>
    isA<SsoException>().having((e) => e.error, 'error', error);
