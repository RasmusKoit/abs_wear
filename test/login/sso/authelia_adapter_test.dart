import 'package:abs_wear/login/data/sso/authelia_adapter.dart';
import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_authelia_server.dart';
import '../../helpers/fake_sso_servers.dart';

const List<SsoField> _login = [SsoField.username, SsoField.password];
const Map<SsoField, String> _password = {
  SsoField.username: 'wear',
  SsoField.password: 'secret',
};

Matcher _error(SsoError error, [String? detail]) => isA<SsoException>()
    .having((e) => e.error, 'error', error)
    .having((e) => e.detail, 'detail', detail ?? anything);

Future<SsoLogin> _start(FakeAutheliaServers servers) async {
  final (login, first) = await SsoLogin.start(
    fakeAbsUrl,
    client: servers.client,
  );
  expect(login.provider, 'Authelia');
  expect((first as SsoPrompt).fields, _login);
  expect(first.retry, isFalse);
  return login;
}

void main() {
  test('logs in through Authelia: username, password, consent', () async {
    final servers = FakeAutheliaServers();
    final login = await _start(servers);
    final consent = await login.submit(_password);
    expect((consent as SsoConsent).app, 'Audiobookshelf');
    final done = await login.submit({});
    expect(((done as SsoDone).data['user'] as Map)['token'], 'legacy-token');
    expect(servers.firstFactorBodies.single, {
      'username': 'wear',
      'password': 'secret',
      'keepMeLoggedIn': false,
      'flow': 'openid_connect',
      'flowID': '5d3a1a33-8472-48c1-9f71-fb2015edeb3e',
    });
    login.close();
  });

  test('without a consent screen it goes straight back', () async {
    final login = await _start(FakeAutheliaServers(consent: false));
    expect(await login.submit(_password), isA<SsoDone>());
  });

  test('a portal under a base path uses the API under it', () async {
    final login = await _start(FakeAutheliaServers(basePath: '/authelia'));
    expect(await login.submit(_password), isA<SsoConsent>());
    expect(await login.submit({}), isA<SsoDone>());
  });

  test('a <base href> on another server is ignored', () async {
    final servers = FakeAutheliaServers(baseHref: 'https://evil.test');
    final login = await _start(servers);
    expect(await login.submit(_password), isA<SsoConsent>());
    final hosts = servers.requests.map((r) => r.url.host);
    expect(hosts, contains('auth.test'));
    expect(hosts, isNot(contains('evil.test')));
  });

  test('a wrong password asks for both again', () async {
    final login = await _start(FakeAutheliaServers());
    final retry = await login.submit({
      SsoField.username: 'wear',
      SsoField.password: 'nope',
    });
    expect((retry as SsoPrompt).fields, _login);
    expect(retry.retry, isTrue);
    expect(await login.submit(_password), isA<SsoConsent>());
  });

  test('asks for a TOTP code, again when it is wrong', () async {
    final servers = FakeAutheliaServers(
      secondFactor: AutheliaSecondFactor.totp,
    );
    final login = await _start(servers);
    final code = await login.submit(_password);
    expect((code as SsoPrompt).fields, [SsoField.code]);
    expect(code.user, 'wear');
    expect(code.retry, isFalse);
    final retry = await login.submit({SsoField.code: '000000'});
    expect((retry as SsoPrompt).fields, [SsoField.code]);
    expect(retry.retry, isTrue);
    expect(await login.submit({SsoField.code: '123456'}), isA<SsoConsent>());
    expect(await login.submit({}), isA<SsoDone>());
  });

  test('a code of the wrong length asks again', () async {
    final login = await _start(
      FakeAutheliaServers(secondFactor: AutheliaSecondFactor.totp),
    );
    await login.submit(_password);
    for (final wrong in ['12345', '1234567', '']) {
      final retry = await login.submit({SsoField.code: wrong});
      expect((retry as SsoPrompt).fields, [SsoField.code]);
      expect(retry.retry, isTrue);
    }
    expect(await login.submit({SsoField.code: '123456'}), isA<SsoConsent>());
  });

  test('an answer without a redirect fails cleanly', () async {
    final login = await _start(
      FakeAutheliaServers(
        secondFactor: AutheliaSecondFactor.totp,
        noRedirect: true,
      ),
    );
    await login.submit(_password);
    await expectLater(
      login.submit({SsoField.code: '123456'}),
      throwsA(_error(SsoError.failed, 'authelia: no redirect')),
    );
  });

  test("grants the consent screen's claims", () async {
    // The fake checks the claims come back in the consent POST.
    final login = await _start(FakeAutheliaServers(claims: true));
    expect(await login.submit(_password), isA<SsoConsent>());
    expect(await login.submit({}), isA<SsoDone>());
  });

  test('WebAuthn and Duo push are unsupported on the watch', () async {
    for (final (factor, detail) in [
      (AutheliaSecondFactor.webauthn, 'webauthn'),
      (AutheliaSecondFactor.duo, 'duo'),
    ]) {
      final login = await _start(FakeAutheliaServers(secondFactor: factor));
      await expectLater(
        login.submit(_password),
        throwsA(_error(SsoError.unsupportedStep, detail)),
      );
    }
  });

  test('a consent screen that wants a new login is unsupported', () async {
    final login = await _start(FakeAutheliaServers(requireLogin: true));
    await expectLater(
      login.submit(_password),
      throwsA(_error(SsoError.unsupportedStep, 'require_login')),
    );
  });

  test('an expired flow fails', () async {
    final login = await _start(FakeAutheliaServers(badFlow: true));
    await expectLater(
      login.submit(_password),
      throwsA(_error(SsoError.failed)),
    );
  });

  group('forPage', () {
    final context = IdpContext(SsoHttp(), (_) async => (null, null));
    final portal = Uri.parse(
      '$fakeAutheliaUrl/?flow=openid_connect'
      '&flow_id=5d3a1a33-8472-48c1-9f71-fb2015edeb3e',
    );

    test("recognises Authelia's portal", () {
      final page = SsoPage(portal, autheliaPortalHtml(fakeAutheliaUrl));
      expect(AutheliaAdapter.forPage(page, context), isNotNull);
    });

    test('recognises the portal without its licence comment', () {
      final html = autheliaPortalHtml(
        fakeAutheliaUrl,
      ).replaceFirst(RegExp('<!--.*?-->', dotAll: true), '');
      expect(html, isNot(contains('Authelia')));
      expect(
        AutheliaAdapter.forPage(SsoPage(portal, html), context),
        isNotNull,
      );
    });

    test('ignores an Authentik page', () {
      final page = SsoPage(
        Uri.parse(
          '$fakeIdpUrl/if/flow/default-authentication-flow/'
          '?next=%2Fapplication%2Fo%2Fauthorize',
        ),
        '<html><head><title>authentik</title></head>'
        '<body><ak-flow-executor></ak-flow-executor></body></html>',
      );
      expect(AutheliaAdapter.forPage(page, context), isNull);
    });

    test('ignores other pages, even with a flow id', () {
      const html = '<html><body><form method="post"></form></body></html>';
      expect(AutheliaAdapter.forPage(SsoPage(portal, html), context), isNull);
      final elsewhere = SsoPage(
        Uri.parse('https://example.com/login'),
        autheliaPortalHtml('https://example.com'),
      );
      expect(AutheliaAdapter.forPage(elsewhere, context), isNull);
    });
  });
}
