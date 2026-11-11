import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_sso_servers.dart';

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
    final (login, first) = await SsoLogin.start(
      fakeAbsUrl,
      client: servers.client,
    );
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
    final (login, _) = await SsoLogin.start(fakeAbsUrl, client: servers.client);
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
    final (login, _) = await SsoLogin.start(fakeAbsUrl, client: servers.client);
    await login.submit({SsoField.username: 'wear'});
    await _expectPrompt(login.submit({SsoField.password: 'secret'}), [
      SsoField.code,
    ]);
    expect(await login.submit({SsoField.code: '123456'}), isA<SsoConsent>());
  });

  test('a passkey-only account is unsupported on the watch', () async {
    final servers = FakeServers(otp: true, webauthnOnly: true);
    final (login, _) = await SsoLogin.start(fakeAbsUrl, client: servers.client);
    await login.submit({SsoField.username: 'wear'});
    await expectLater(
      login.submit({SsoField.password: 'secret'}),
      throwsA(_error(SsoError.unsupportedStep)),
    );
  });

  test('a server without SSO', () async {
    final servers = FakeServers(openid: false);
    await expectLater(
      SsoLogin.start(fakeAbsUrl, client: servers.client),
      throwsA(_error(SsoError.notEnabled)),
    );
  });

  test('a server that does not allow the redirect URI yet', () async {
    final servers = FakeServers(startStatus: 400);
    await expectLater(
      SsoLogin.start(fakeAbsUrl, client: servers.client),
      throwsA(_error(SsoError.redirectNotAllowed)),
    );
  });

  test('an identity provider the watch cannot drive', () async {
    final servers = FakeServers(idpPagePath: '/realms/x/login');
    await expectLater(
      SsoLogin.start(fakeAbsUrl, client: servers.client),
      throwsA(_error(SsoError.unsupportedProvider)),
    );
  });

  Future<void> loginExpecting(FakeServers servers, SsoError error) async {
    final (login, _) = await SsoLogin.start(fakeAbsUrl, client: servers.client);
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
